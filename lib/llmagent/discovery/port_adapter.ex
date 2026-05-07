defmodule LLMAgent.Discovery.PortAdapter do
  @moduledoc """
  Supervises an external discovery shim and translates its EDN-on-stdout
  output into `LLMAgent.Tools.Discovery` calls.

  Spawns the shim as an Erlang `Port` in `:line` mode. Each complete line is
  decoded with `LLMAgent.Discovery.Wire.decode/1`. Successful decodes drive
  the registry:

  - `{:register, ad}` → `Discovery.register/1`, falling back to `update/1` on
    `:duplicate_id`. This makes re-emit-on-shim-restart idempotent.
  - `{:expire, id}` → `Discovery.unregister/1`.

  Decode failures are logged and skipped — the adapter does not crash on
  malformed input. Port closure terminates the GenServer; the supervisor
  decides whether to restart.

  Configure via `start_link/1`:

      {LLMAgent.Discovery.PortAdapter,
        name: :avahi_llama,
        command: "/usr/bin/tclsh",
        args: ["priv/discovery/avahi-llama.tcl"],
        env: []}

  See `docs/superpowers/specs/2026-05-07-mdns-llm-discovery.md`.
  """

  use GenServer
  require Logger

  alias LLMAgent.Discovery.Wire
  alias LLMAgent.Tools.Discovery, as: Reg

  @enforce_keys [:name, :port]
  defstruct [:name, :port]

  @type opts :: [
          name: atom(),
          command: binary(),
          args: [binary()],
          env: [{charlist(), charlist()}]
        ]

  @doc "Start a PortAdapter under a supervisor. `:name` and `:command` are required."
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: process_name(name))
  end

  defp process_name(name), do: {:global, {__MODULE__, name}}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    cmd  = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    env  = Keyword.get(opts, :env, [])

    port = Port.open({:spawn_executable, cmd}, [
      :binary,
      :exit_status,
      {:line, 65_536},
      {:args, args},
      {:env, env}
    ])

    {:ok, %__MODULE__{name: Keyword.fetch!(opts, :name), port: port}}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    handle_line(line, state)
    {:noreply, state}
  end

  def handle_info({port, {:data, {:noeol, _}}}, %{port: port} = state) do
    Logger.warning("PortAdapter #{state.name}: shim emitted line over 64KiB; dropping")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("PortAdapter #{state.name}: shim exited with status #{status}")
    {:stop, {:shim_exit, status}, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp handle_line(line, state) do
    try do
      do_handle_line(line, state)
    rescue
      e ->
        Logger.warning("PortAdapter #{state.name}: handle_line raised: #{inspect(e)} on line: #{inspect(line)}")
        :ok
    end
  end

  defp do_handle_line(line, state) do
    case Wire.decode(line) do
      {:ok, {:register, ad}} ->
        case Reg.register(ad) do
          :ok ->
            :ok

          {:error, :duplicate_id} ->
            Reg.update(ad)

          {:error, reason} ->
            Logger.warning("PortAdapter #{state.name}: register failed: #{inspect(reason)}")
        end

      {:ok, {:expire, id}} ->
        Reg.unregister(id)

      {:error, reason} ->
        Logger.warning(
          "PortAdapter #{state.name}: decode failed: #{inspect(reason)} for line: #{inspect(line)}"
        )
    end
  end

  @impl true
  def terminate(_reason, %{port: port}) do
    if is_port(port) and Port.info(port) != nil do
      Port.close(port)
    end

    :ok
  end
end

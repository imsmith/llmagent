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
  defstruct [:name, :port, :os_pid]

  # Grace between SIGTERM and SIGKILL when reaping a shim.
  @term_grace_ms 200

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

    # Recorded at open time: once the port has closed, Port.info/2 returns nil
    # and the pid needed to signal the child is gone with it.
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, p} -> p
        nil -> nil
      end

    {:ok, %__MODULE__{name: Keyword.fetch!(opts, :name), port: port, os_pid: os_pid}}
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
      # Malformed shim output is expected and must not take the adapter down;
      # these are the shapes a bad line can produce on the way through the
      # codec. Anything else is a real defect and is left to crash.
      e in [ArgumentError, KeyError, MatchError, FunctionClauseError] ->
        Logger.warning(
          "PortAdapter #{state.name}: handle_line raised: #{inspect(e)} on line: #{inspect(line)}"
        )

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
  def terminate(_reason, %{port: port, os_pid: os_pid}) do
    if is_port(port) and Port.info(port) != nil do
      Port.close(port)
    end

    reap(os_pid)
    :ok
  end

  # Closing the port closes the pipes; it does not signal the program. A shim
  # that does not exit on stdin EOF survives the adapter, keeps scanning, and
  # keeps holding the stdout it inherited — which hangs whatever is reading
  # that pipe, `mix test` included. Shims watch stdin for their half of this;
  # this half covers the ones that do not.
  @spec reap(non_neg_integer() | nil) :: :ok
  defp reap(nil), do: :ok

  defp reap(os_pid) do
    signal(os_pid, "-TERM")
    Process.sleep(@term_grace_ms)

    if os_alive?(os_pid) do
      signal(os_pid, "-KILL")
    end

    :ok
  end

  defp signal(os_pid, sig) do
    System.cmd("kill", [sig, Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    # `kill` missing from PATH is not worth taking a shutdown down for.
    ErlangError -> :ok
  end

  defp os_alive?(os_pid) do
    {_, status} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    status == 0
  rescue
    ErlangError -> false
  end
end

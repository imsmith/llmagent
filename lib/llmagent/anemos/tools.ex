defmodule LLMAgent.Anemos.Tools do
  @moduledoc """
  The part of `LLMAgent.Anemos` that knows which coordinate is behind each
  module name and under which policy a tool may be called.

  A verb asks this process, at every call, for the policy and for the
  coordinate behind its name. Stop it and every tool verb answers
  `{:error, :detached}`; start it with another policy and the rights
  change. The runtime's own module registry is write-once, so the *names*
  stay bound; what they reach is decided here.
  """

  use GenServer

  require Logger

  alias LLMAgent.{ToolQuery, Tool.Policy, Tools.Discovery}

  @default_timeout_ms 4_000

  @doc false
  def default_timeout_ms, do: @default_timeout_ms

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    runtime = Keyword.fetch!(opts, :runtime)
    GenServer.start_link(__MODULE__, opts, name: name_for(runtime))
  end

  @doc "The registered name of the tools process serving `runtime`."
  @spec name_for(atom()) :: atom()
  def name_for(runtime), do: :"#{runtime}.llmagent.tools"

  @doc "The Anemos module name for a coordinate: `resource.net` is `RESOURCE_NET`."
  @spec module_name(String.t()) :: String.t()
  def module_name(coordinate), do: coordinate |> String.replace(".", "_") |> String.upcase()

  @doc "The coordinate, policy and deadline behind `name`, from the live process."
  @spec resolve(atom(), String.t()) ::
          {:ok, String.t(), Policy.t(), pos_integer()}
          | {:error, :detached | {:unknown_tool, String.t()}}
  def resolve(runtime, name) do
    GenServer.call(name_for(runtime), {:resolve, name})
  catch
    :exit, _ -> {:error, :detached}
  end

  @impl true
  def init(opts) do
    runtime = Keyword.fetch!(opts, :runtime)
    policy = Keyword.get(opts, :policy, %Policy{})

    if policy.require_approval != [] do
      {:stop, {:require_approval_not_supported, policy.require_approval}}
    else
      everything = ToolQuery.new(%{coordinate: "*"})
      :ok = Discovery.subscribe(everything, self())
      {:ok, ads} = Discovery.find_all(everything)

      state = %{
        runtime: runtime,
        policy: policy,
        timeout_ms: Keyword.get(opts, :verb_timeout_ms, @default_timeout_ms),
        # module name => coordinate
        names: %{}
      }

      {:ok, Enum.reduce(ads, state, &bind(&2, &1.coordinate))}
    end
  end

  @impl true
  def handle_info({event, _id, coordinate}, state) when event in [:tool_added, :tool_updated] do
    {:noreply, bind(state, coordinate)}
  end

  # Only the name this coordinate held, and only if it still holds it: a
  # later ad that took the name over is not unbound by the earlier one
  # leaving.
  def handle_info({:tool_removed, _id, coordinate, _reason}, state) do
    name = module_name(coordinate)

    case Map.get(state.names, name) do
      ^coordinate -> {:noreply, %{state | names: Map.delete(state.names, name)}}
      _ -> {:noreply, state}
    end
  end

  @impl true
  def handle_call({:resolve, name}, _from, state) do
    reply =
      case Map.fetch(state.names, name) do
        {:ok, coordinate} -> {:ok, coordinate, state.policy, state.timeout_ms}
        :error -> {:error, {:unknown_tool, name}}
      end

    {:reply, reply, state}
  end

  # The name is a lossy function of the coordinate: `a.b_c` and `a.b.c`
  # collide, and so would anything mDNS or the tuple space announced to
  # collide with a name a policy already uses. A name keeps its first
  # coordinate until that coordinate leaves. Also warned about: a name the
  # lexer cannot read, which is bound and unreachable.
  defp bind(state, coordinate) do
    name = module_name(coordinate)

    case Map.get(state.names, name) do
      nil ->
        unless lexable?(name) do
          Logger.warning(
            "[llmagent] #{coordinate} would be #{name}, which an Anemos policy cannot write"
          )
        end

        register(state.runtime, name)
        %{state | names: Map.put(state.names, name, coordinate)}

      ^coordinate ->
        state

      holder ->
        Logger.warning(
          "[llmagent] #{coordinate} would be #{name}, which #{holder} already is in " <>
            "#{state.runtime}; the newcomer is not reachable from policy"
        )

        state
    end
  end

  defp register(runtime, name) do
    case Anemos.Runtime.register(runtime, name, LLMAgent.Anemos) do
      :ok ->
        :ok

      {:error, {:already_registered, other}} ->
        Logger.warning(
          "[llmagent] #{name} is bound to #{inspect(other)} in #{runtime}; " <>
            "the tool is not reachable under that name"
        )
    end
  end

  # What `Anemos.Lexer` reads as a module id: uppercase segments joined by
  # underscores, optionally ending in one lowercase segment.
  defp lexable?(name),
    do: Regex.match?(~r/^[A-Z][A-Z0-9]*(_[A-Z0-9]+)*(_[a-z][a-z0-9_-]*)?$/, name)
end

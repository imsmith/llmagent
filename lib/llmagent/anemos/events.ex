defmodule LLMAgent.Anemos.Events do
  @moduledoc """
  The substrate's events, dispatched into an Anemos runtime.

  Every event that goes through `LLMAgent.Events.emit/4` — a file change
  seen by inotify, a hub request, an agent message — arrives in the
  runtime as an event named after its topic: `tool.inotify.event` is
  `TOOL_INOTIFY_EVENT`, `hub.request` is `HUB_REQUEST`. The topic is the
  event's context path, so `context "tool.inotify" { when ... }` filters by
  it, and the event's data are the `?` facts, with `?topic`, `?type`,
  `?source` and `?id` beside them.

  Tool discovery arrives the same way: `TOOL_ADDED`, `TOOL_UPDATED` and
  `TOOL_REMOVED`, with the coordinate as context path and `?coordinate`
  and `?id` as facts.

  ## Loops have a ceiling

  A rule calls a tool, the tool emits, the event reaches the rule. Across
  the bus there is no call depth to bound that, so causation is counted
  instead: every event carries a correlation id — its own id if it has
  none — and everything the rules do about it, tool emits included, runs
  under that id and inherits it. Past `:hop_limit` events (default 64) on
  one correlation, the rest are dropped and the log says so once.

  A runtime's own emits (through `LLMAgent.Anemos.Channel`) are not fed
  back into it; `emit ... as :label` is the way to chain rules within a
  runtime. Another runtime's emits are events like any other.

  ## Its own process

  Dispatching into the runtime blocks until the rules have run, and a rule
  may be calling a tool that is asking the tools process for its policy at
  that moment. Events are dispatched one at a time, in arrival order; an
  event nothing listens for is not dispatched at all.
  """

  use GenServer

  require Logger

  alias Comn.Events.EventStruct
  alias LLMAgent.{EventBus, ToolQuery, Tools.Discovery}

  @default_hop_limit 64
  @default_dispatch_timeout_ms 5_000
  # ponytail: hop counts are forgotten after a minute; a correlation that
  # lives longer than that starts counting again.
  @forget_after_ms 60_000

  @doc "The topic every event is also broadcast on, for a subscriber that wants them all."
  @spec every_topic() :: String.t()
  def every_topic, do: "*"

  @doc """
  Options: `:runtime` (required), `:hop_limit` (default #{@default_hop_limit}),
  `:dispatch_timeout_ms` (default #{@default_dispatch_timeout_ms}).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    runtime = Keyword.fetch!(opts, :runtime)
    GenServer.start_link(__MODULE__, opts, name: name_for(runtime))
  end

  @doc "The registered name of the events process serving `runtime`."
  @spec name_for(atom()) :: atom()
  def name_for(runtime), do: :"#{runtime}.llmagent.events"

  @doc "The Anemos event name for a topic: `tool.inotify.event` is `TOOL_INOTIFY_EVENT`."
  @spec event_name(String.t()) :: String.t()
  def event_name(topic), do: topic |> String.upcase() |> String.replace(~r/[^A-Z0-9]+/, "_")

  @impl true
  def init(opts) do
    {:ok, _} = EventBus.subscribe(every_topic())
    :ok = Discovery.subscribe(ToolQuery.new(%{coordinate: "*"}), self())
    Process.send_after(self(), :forget, @forget_after_ms)

    {:ok,
     %{
       runtime: Keyword.fetch!(opts, :runtime),
       hop_limit: Keyword.get(opts, :hop_limit, @default_hop_limit),
       timeout: Keyword.get(opts, :dispatch_timeout_ms, @default_dispatch_timeout_ms),
       # correlation id => {hops, last seen (monotonic ms)}
       hops: %{}
     }}
  end

  @impl true
  def handle_info({:event, "*", %EventStruct{} = event}, state) do
    if own?(event, state.runtime) do
      {:noreply, state}
    else
      facts =
        event.data
        |> facts()
        |> Map.merge(%{
          "topic" => event.topic,
          "type" => stringish(event.type),
          "source" => stringish(event.source),
          "id" => event.id
        })

      correlation = event.correlation_id || event.id

      {:noreply, dispatch(state, event_name(event.topic), event.topic, facts, correlation)}
    end
  end

  def handle_info({change, id, coordinate}, state) when change in [:tool_added, :tool_updated] do
    facts = %{"id" => id, "coordinate" => coordinate}
    {:noreply, dispatch(state, event_name("#{change}"), coordinate, facts, id)}
  end

  def handle_info({:tool_removed, id, coordinate, reason}, state) do
    facts = %{"id" => id, "coordinate" => coordinate, "reason" => stringish(reason)}
    {:noreply, dispatch(state, "TOOL_REMOVED", coordinate, facts, id)}
  end

  def handle_info(:forget, state) do
    cutoff = System.monotonic_time(:millisecond) - @forget_after_ms
    hops = Map.reject(state.hops, fn {_id, {_n, seen}} -> seen < cutoff end)
    Process.send_after(self(), :forget, @forget_after_ms)
    {:noreply, %{state | hops: hops}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp own?(%EventStruct{source: {LLMAgent.Anemos.Channel, runtime}}, runtime), do: true
  defp own?(_event, _runtime), do: false

  # A `?fact` is looked up by string. Top-level keys only: a nested map is a
  # value a rule can hand to a verb, not something it can reach into. Data
  # comes from tools and the network, so every shape is taken.
  defp facts(%_{} = struct), do: struct |> Map.from_struct() |> facts()
  defp facts(%{} = data), do: Map.new(data, fn {k, v} -> {stringish(k), v} end)
  defp facts(other), do: %{"data" => other}

  defp stringish(value) when is_binary(value), do: value
  defp stringish(value) when is_atom(value), do: Atom.to_string(value)
  defp stringish(value), do: inspect(value)

  defp dispatch(state, name, context_path, facts, correlation) do
    {hops, seen} = Map.get(state.hops, correlation, {0, nil})
    now = System.monotonic_time(:millisecond)

    cond do
      hops >= state.hop_limit ->
        if hops == state.hop_limit do
          Logger.warning(
            "[llmagent] #{state.runtime}: #{name} is the #{hops}th event on one chain of " <>
              "cause and effect (#{correlation}); dropping the rest of it"
          )
        end

        %{state | hops: Map.put(state.hops, correlation, {hops + 1, seen || now})}

      not wanted?(state, name) ->
        state

      true ->
        context = %{context_path: context_path, context_data: facts, correlation_id: correlation}
        run(state, name, context)
        %{state | hops: Map.put(state.hops, correlation, {hops + 1, now})}
    end
  end

  # Nothing subscribed, nothing dispatched: no trace entry, no persist, no
  # condition round-trip for an event the policy set does not mention.
  defp wanted?(state, name) do
    case Anemos.Runtime.explain(state.runtime, name, %{}, timeout: state.timeout) do
      %{rules: [], conditions: []} -> false
      _ -> true
    end
  catch
    :exit, _ -> true
  end

  # The rules' results are theirs; what matters here is that an event the
  # runtime could not take in time does not take this process with it. The
  # dispatcher may still run it after the deadline; the log says as much.
  defp run(state, name, context) do
    Anemos.Runtime.dispatch(state.runtime, name, context, timeout: state.timeout)
  catch
    :exit, reason ->
      Logger.warning(
        "[llmagent] #{state.runtime} did not answer #{name} within #{state.timeout}ms " <>
          "(#{inspect(tag(reason))}); it may still run"
      )
  end

  defp tag({tag, _}) when is_atom(tag), do: tag
  defp tag(other), do: other
end

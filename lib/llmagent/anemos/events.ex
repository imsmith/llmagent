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

  What a runtime itself emits (through `LLMAgent.Anemos.Channel`) goes to
  the rest of the system and is not fed back into any runtime: a rule
  that listened to its own emits would be a loop with no ceiling. Within a
  runtime, `emit ... as :label` is the way to chain rules.

  Its own process, not the tools process: dispatching into the runtime
  blocks until the rules have run, and a rule may be calling a tool that
  is asking the tools process for its policy at that moment.
  """

  use GenServer

  require Logger

  alias Comn.Events.EventStruct
  alias LLMAgent.{EventBus, ToolQuery, Tools.Discovery}

  @doc "The topic every event is also broadcast on, for a subscriber that wants them all."
  @spec every_topic() :: String.t()
  def every_topic, do: "*"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    runtime = Keyword.fetch!(opts, :runtime)
    GenServer.start_link(__MODULE__, opts, name: :"#{runtime}.llmagent.events")
  end

  @doc "The Anemos event name for a topic: `tool.inotify.event` is `TOOL_INOTIFY_EVENT`."
  @spec event_name(String.t()) :: String.t()
  def event_name(topic), do: topic |> String.upcase() |> String.replace(~r/[^A-Z0-9]+/, "_")

  @impl true
  def init(opts) do
    {:ok, _} = EventBus.subscribe(every_topic())
    :ok = Discovery.subscribe(ToolQuery.new(%{coordinate: "*"}), self())
    {:ok, %{runtime: Keyword.fetch!(opts, :runtime)}}
  end

  @impl true
  def handle_info({:event, "*", %EventStruct{source: LLMAgent.Anemos.Channel}}, state),
    do: {:noreply, state}

  def handle_info({:event, "*", %EventStruct{} = event}, state) do
    facts =
      event.data
      |> stringify()
      |> Map.merge(%{
        "topic" => event.topic,
        "type" => to_string(event.type),
        "source" => inspect(event.source),
        "id" => event.id
      })

    dispatch(state.runtime, event_name(event.topic), event.topic, facts)
    {:noreply, state}
  end

  def handle_info({change, id, coordinate}, state) when change in [:tool_added, :tool_updated] do
    dispatch(state.runtime, event_name("#{change}"), coordinate, %{
      "id" => id,
      "coordinate" => coordinate
    })

    {:noreply, state}
  end

  def handle_info({:tool_removed, id, coordinate, reason}, state) do
    facts = %{"id" => id, "coordinate" => coordinate, "reason" => to_string(reason)}
    dispatch(state.runtime, "TOOL_REMOVED", coordinate, facts)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # A `?fact` is looked up by string. Top-level keys only: a nested map is a
  # value a rule can hand to a verb, not something it can reach into.
  defp stringify(%{} = data), do: Map.new(data, fn {k, v} -> {to_string(k), v} end)
  defp stringify(other), do: %{"data" => other}

  # The rules' results are theirs; what matters here is that an event the
  # runtime could not take does not take this process with it.
  defp dispatch(runtime, name, context_path, facts) do
    Anemos.Runtime.dispatch(runtime, name, %{context_path: context_path, context_data: facts})
  catch
    :exit, reason ->
      Logger.warning("[llmagent] #{runtime} did not take #{name}: #{inspect(elem_or(reason))}")
  end

  defp elem_or({tag, _}) when is_atom(tag), do: tag
  defp elem_or(other), do: other
end

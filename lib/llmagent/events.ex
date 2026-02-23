defmodule LLMAgent.Events do
  @moduledoc """
  Public event emission for LLMAgent and tool modules.

  Wraps EventLog.record + EventBus.broadcast with automatic
  context enrichment from Comn.Contexts (process dictionary).

  ## Examples

      iex> LLMAgent.EventLog.clear()
      iex> LLMAgent.Events.emit(:test, "doctest.events", %{key: "val"}, :doctest)
      :ok
      iex> [event] = LLMAgent.EventLog.for_topic("doctest.events")
      iex> event.type
      :test
      iex> event.data.key
      "val"
      iex> event.source
      :doctest
  """

  alias Comn.Events.EventStruct
  alias Comn.Contexts

  @doc """
  Emit an event, recording it to EventLog and broadcasting via EventBus.

  Automatically attaches context fields (request_id, trace_id, correlation_id)
  from the current process context when available.

  ## Examples

  Without context — no `:context` key in event data:

      iex> Process.delete(:comn_context)
      iex> LLMAgent.EventLog.clear()
      iex> LLMAgent.Events.emit(:plain, "doctest.no_ctx", %{a: 1})
      :ok
      iex> [e] = LLMAgent.EventLog.for_topic("doctest.no_ctx")
      iex> Map.has_key?(e.data, :context)
      false

  With context — attaches request_id:

      iex> Comn.Contexts.new(%{request_id: "req_doctest"})
      iex> LLMAgent.EventLog.clear()
      iex> LLMAgent.Events.emit(:ctx, "doctest.with_ctx", %{b: 2})
      :ok
      iex> [e] = LLMAgent.EventLog.for_topic("doctest.with_ctx")
      iex> e.data.context.request_id
      "req_doctest"
      iex> Process.delete(:comn_context)
  """
  @spec emit(atom(), String.t(), map(), module() | atom()) :: :ok
  def emit(type, topic, data, source \\ __MODULE__) do
    data = attach_context(data)
    event = EventStruct.new(type, topic, data, source)
    LLMAgent.EventLog.record(event)
    LLMAgent.EventBus.broadcast(topic, event)
    :ok
  rescue
    _ -> :ok
  end

  defp attach_context(data) when is_map(data) do
    case Contexts.get() do
      nil ->
        data

      ctx ->
        context_info =
          %{}
          |> maybe_put(:request_id, ctx.request_id)
          |> maybe_put(:trace_id, ctx.trace_id)
          |> maybe_put(:correlation_id, ctx.correlation_id)

        if map_size(context_info) > 0 do
          Map.put(data, :context, context_info)
        else
          data
        end
    end
  end

  defp attach_context(data), do: data

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)
end

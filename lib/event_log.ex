defmodule LLMAgent.EventLog do
  @moduledoc """
  In-memory, immutable event log that records and queries all agent/tool activity.
  """

  use Agent

  alias LLMAgent.Event

  @type event :: struct()

  ## Public API

  def start_link(_opts) do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  @doc "Records any struct that implements the LLMAgent.Event protocol."
  @spec record(term()) :: :ok
  def record(term) do
    event = Event.to_event(term)
    Agent.update(__MODULE__, fn log -> [event | log] end)
  end

  @doc "Returns all logged events, oldest to newest."
  @spec all() :: [event]
  def all do
    Agent.get(__MODULE__, &Enum.reverse/1)
  end

  @doc "Returns all events matching a topic."
  @spec for_topic(String.t()) :: [event]
  def for_topic(topic) do
    Agent.get(__MODULE__, fn log ->
      log
      |> Enum.filter(&(&1.topic == topic))
      |> Enum.reverse()
    end)
  end

  @doc "Returns all events of a given type (e.g., :start, :stop, :message)."
  @spec for_type(atom()) :: [event]
  def for_type(type) do
    Agent.get(__MODULE__, fn log ->
      log
      |> Enum.filter(&(&1.type == type))
      |> Enum.reverse()
    end)
  end

  @doc "Returns all events newer than an ISO8601 datetime string."
  @spec since(String.t()) :: [event]
  def since(iso_timestamp) do
    {:ok, dt, _} = DateTime.from_iso8601(iso_timestamp)

    Agent.get(__MODULE__, fn log ->
      log
      |> Enum.filter(fn event ->
        case DateTime.from_iso8601(event.timestamp) do
          {:ok, t, _} -> DateTime.compare(t, dt) == :gt
          _ -> false
        end
      end)
      |> Enum.reverse()
    end)
  end

  @doc "Clears the event log. Use with caution."
  def clear do
    Agent.update(__MODULE__, fn _ -> [] end)
  end
end

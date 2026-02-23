defmodule LLMAgent.EventLog do
  @moduledoc """
  In-memory, immutable event log that records and queries all agent/tool activity.

  ## Examples

      iex> LLMAgent.EventLog.clear()
      iex> event = Comn.Events.EventStruct.new(:test, "doctest.log", %{val: 1})
      iex> LLMAgent.EventLog.record(event)
      iex> [recorded] = LLMAgent.EventLog.all()
      iex> recorded.type
      :test
      iex> recorded.data
      %{val: 1}
  """

  use Agent

  alias Comn.Event

  @type event :: struct()

  ## Public API

  def start_link(_opts) do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  @doc """
  Records any struct that implements the Comn.Event protocol.

  ## Examples

      iex> LLMAgent.EventLog.clear()
      iex> LLMAgent.EventLog.record(Comn.Events.EventStruct.new(:info, "doctest.record", %{}))
      iex> length(LLMAgent.EventLog.all())
      1
  """
  @spec record(term()) :: :ok
  def record(term) do
    event = Event.to_event(term)
    Agent.update(__MODULE__, fn log -> [event | log] end)
  end

  @doc """
  Returns all logged events, oldest to newest.

  ## Examples

      iex> LLMAgent.EventLog.clear()
      iex> LLMAgent.EventLog.all()
      []
  """
  @spec all() :: [event]
  def all do
    Agent.get(__MODULE__, &Enum.reverse/1)
  end

  @doc """
  Returns all events matching a topic.

  ## Examples

      iex> LLMAgent.EventLog.clear()
      iex> LLMAgent.EventLog.record(Comn.Events.EventStruct.new(:a, "x", %{}))
      iex> LLMAgent.EventLog.record(Comn.Events.EventStruct.new(:b, "y", %{}))
      iex> LLMAgent.EventLog.for_topic("x") |> length()
      1
  """
  @spec for_topic(String.t()) :: [event]
  def for_topic(topic) do
    Agent.get(__MODULE__, fn log ->
      log
      |> Enum.filter(&(&1.topic == topic))
      |> Enum.reverse()
    end)
  end

  @doc """
  Returns all events of a given type (e.g., :start, :stop, :message).

  ## Examples

      iex> LLMAgent.EventLog.clear()
      iex> LLMAgent.EventLog.record(Comn.Events.EventStruct.new(:alert, "t", %{}))
      iex> LLMAgent.EventLog.record(Comn.Events.EventStruct.new(:info, "t", %{}))
      iex> LLMAgent.EventLog.for_type(:alert) |> length()
      1
  """
  @spec for_type(atom()) :: [event]
  def for_type(type) do
    Agent.get(__MODULE__, fn log ->
      log
      |> Enum.filter(&(&1.type == type))
      |> Enum.reverse()
    end)
  end

  @doc """
  Returns all events newer than an ISO8601 datetime string.

  ## Examples

      iex> LLMAgent.EventLog.clear()
      iex> LLMAgent.EventLog.record(Comn.Events.EventStruct.new(:a, "t", %{}))
      iex> LLMAgent.EventLog.since("2000-01-01T00:00:00Z") |> length()
      1
      iex> LLMAgent.EventLog.since("2099-01-01T00:00:00Z") |> length()
      0
  """
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

  @doc """
  Clears the event log.

  ## Examples

      iex> LLMAgent.EventLog.record(Comn.Events.EventStruct.new(:x, "t", %{}))
      iex> LLMAgent.EventLog.clear()
      iex> LLMAgent.EventLog.all()
      []
  """
  def clear do
    Agent.update(__MODULE__, fn _ -> [] end)
  end
end

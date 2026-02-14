defmodule LLMAgent.EventLogTest do
  use ExUnit.Case, async: false

  alias LLMAgent.EventLog
  alias Comn.Events.EventStruct

  setup do
    EventLog.clear()
    :ok
  end

  test "records and retrieves events" do
    event = EventStruct.new(:test, "test.topic", "hello")
    EventLog.record(event)

    events = EventLog.all()
    assert length(events) == 1
    assert hd(events).type == :test
    assert hd(events).topic == "test.topic"
    assert hd(events).data == "hello"
  end

  test "for_topic filters by topic" do
    EventLog.record(EventStruct.new(:a, "topic.one", "data1"))
    EventLog.record(EventStruct.new(:b, "topic.two", "data2"))
    EventLog.record(EventStruct.new(:c, "topic.one", "data3"))

    events = EventLog.for_topic("topic.one")
    assert length(events) == 2
    assert Enum.all?(events, &(&1.topic == "topic.one"))
  end

  test "for_type filters by type" do
    EventLog.record(EventStruct.new(:invocation, "tool.bash", %{}))
    EventLog.record(EventStruct.new(:error, "agent.error", %{}))
    EventLog.record(EventStruct.new(:invocation, "tool.web", %{}))

    events = EventLog.for_type(:invocation)
    assert length(events) == 2
    assert Enum.all?(events, &(&1.type == :invocation))
  end

  test "since filters by timestamp" do
    EventLog.record(EventStruct.new(:old, "test", "old"))
    Process.sleep(10)
    cutoff = DateTime.utc_now() |> DateTime.to_iso8601()
    Process.sleep(10)
    EventLog.record(EventStruct.new(:new, "test", "new"))

    events = EventLog.since(cutoff)
    assert length(events) == 1
    assert hd(events).type == :new
  end

  test "clear empties the log" do
    EventLog.record(EventStruct.new(:test, "t", "d"))
    assert length(EventLog.all()) == 1

    EventLog.clear()
    assert EventLog.all() == []
  end

  test "events are ordered oldest to newest" do
    EventLog.record(EventStruct.new(:first, "t", "1"))
    Process.sleep(2)
    EventLog.record(EventStruct.new(:second, "t", "2"))
    Process.sleep(2)
    EventLog.record(EventStruct.new(:third, "t", "3"))

    events = EventLog.all()
    assert length(events) == 3
    assert Enum.map(events, & &1.type) == [:first, :second, :third]
  end
end

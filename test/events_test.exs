defmodule LLMAgent.EventsTest do
  @moduledoc """
  Tests for LLMAgent.Events — public event emission with context enrichment.
  """
  use ExUnit.Case, async: false

  alias LLMAgent.Events
  alias LLMAgent.EventLog
  alias LLMAgent.EventBus
  alias Comn.Contexts
  alias Comn.Events.EventStruct

  setup do
    EventLog.clear()
    Process.delete(:comn_context)
    :ok
  end

  describe "emit/4 without context" do
    test "records event to EventLog" do
      Events.emit(:test, "test.topic", %{foo: "bar"}, __MODULE__)

      events = EventLog.for_topic("test.topic")
      assert length(events) == 1
      assert hd(events).type == :test
      assert hd(events).data.foo == "bar"
      assert hd(events).source == __MODULE__
    end

    test "broadcasts event via EventBus" do
      EventBus.subscribe("test.broadcast")

      Events.emit(:test, "test.broadcast", %{x: 1}, __MODULE__)

      assert_receive {:event, "test.broadcast", %EventStruct{type: :test}}
    end

    test "event data has no :context key when no context set" do
      Events.emit(:test, "test.no_ctx", %{val: true}, __MODULE__)

      [event] = EventLog.for_topic("test.no_ctx")
      refute Map.has_key?(event.data, :context)
    end
  end

  describe "emit/4 with context" do
    test "attaches request_id and trace_id from process context" do
      Contexts.new(%{request_id: "req_abc", trace_id: "trace_xyz"})

      Events.emit(:test, "test.with_ctx", %{action: "go"}, __MODULE__)

      [event] = EventLog.for_topic("test.with_ctx")
      assert event.data.context.request_id == "req_abc"
      assert event.data.context.trace_id == "trace_xyz"
      assert event.data.action == "go"
    end

    test "attaches correlation_id when present" do
      Contexts.new(%{request_id: "r1", correlation_id: "corr_42"})

      Events.emit(:test, "test.corr", %{}, __MODULE__)

      [event] = EventLog.for_topic("test.corr")
      assert event.data.context.request_id == "r1"
      assert event.data.context.correlation_id == "corr_42"
    end

    test "omits nil context fields" do
      Contexts.new(%{request_id: "r2"})

      Events.emit(:test, "test.partial_ctx", %{}, __MODULE__)

      [event] = EventLog.for_topic("test.partial_ctx")
      assert event.data.context.request_id == "r2"
      refute Map.has_key?(event.data.context, :trace_id)
      refute Map.has_key?(event.data.context, :correlation_id)
    end

    test "does not attach context when all tracing fields are nil" do
      Contexts.new(%{actor: "agent"})

      Events.emit(:test, "test.no_trace_fields", %{}, __MODULE__)

      [event] = EventLog.for_topic("test.no_trace_fields")
      refute Map.has_key?(event.data, :context)
    end
  end

  describe "emit/4 defaults" do
    test "source defaults to LLMAgent.Events when not provided" do
      Events.emit(:test, "test.default_source", %{})

      [event] = EventLog.for_topic("test.default_source")
      assert event.source == LLMAgent.Events
    end
  end
end

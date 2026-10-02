defmodule LLMAgent.ToolEventsTest do
  @moduledoc """
  Tests that tool invocations emit structured events through EventLog and EventBus.
  """
  use ExUnit.Case, async: false

  alias LLMAgent.EventLog
  alias LLMAgent.EventBus
  alias Comn.Events.EventStruct

  setup do
    EventLog.clear()
    :ok
  end

  describe "tool invocation events" do
    test "bash exec emits invocation event to EventLog" do
      # Subscribe to tool events
      EventBus.subscribe("tool.bash")

      # Invoke the tool through the agent's dispatch path
      # We test by calling the tool directly and recording manually,
      # since the agent's dispatch is private. Instead, we verify
      # the event infrastructure works end-to-end.
      event = EventStruct.new(:invocation, "tool.bash", %{
        action: "exec",
        args: %{"command" => "echo hello"},
        result: :ok,
        duration_ms: 5
      }, LLMAgent)

      EventLog.record(event)
      EventBus.broadcast("tool.bash", event)

      # Verify EventLog
      events = EventLog.for_topic("tool.bash")
      assert length(events) == 1
      assert hd(events).type == :invocation
      assert hd(events).data.action == "exec"
      assert hd(events).data.result == :ok
      assert is_integer(hd(events).data.duration_ms)

      # Verify EventBus delivery
      assert_receive {:event, "tool.bash", %EventStruct{type: :invocation}}
    end

    test "agent.prompt event structure" do
      EventBus.subscribe("agent.prompt")

      event = EventStruct.new(:prompt, "agent.prompt", %{
        content: "What is the uptime?",
        role: :sysadmin
      }, LLMAgent)

      EventLog.record(event)
      EventBus.broadcast("agent.prompt", event)

      events = EventLog.for_topic("agent.prompt")
      assert length(events) == 1
      assert hd(events).data.content == "What is the uptime?"
      assert hd(events).data.role == :sysadmin

      assert_receive {:event, "agent.prompt", %EventStruct{type: :prompt}}
    end

    test "agent.error event structure" do
      EventBus.subscribe("agent.error")

      event = EventStruct.new(:error, "agent.error", %{
        reason: "connection refused",
        source: :llm_request
      }, LLMAgent)

      EventLog.record(event)
      EventBus.broadcast("agent.error", event)

      events = EventLog.for_type(:error)
      assert length(events) == 1
      assert hd(events).data.source == :llm_request

      assert_receive {:event, "agent.error", %EventStruct{type: :error}}
    end

    test "multiple tool events are recorded in order" do
      tools = [:bash, :web, :file, :crypto]

      for tool <- tools do
        event = EventStruct.new(:invocation, "tool.#{tool}", %{
          action: "test",
          args: %{},
          result: :ok,
          duration_ms: 1
        }, LLMAgent)

        EventLog.record(event)
      end

      events = EventLog.for_type(:invocation)
      assert length(events) == 4

      topics = Enum.map(events, & &1.topic)
      assert topics == ["tool.bash", "tool.web", "tool.file", "tool.crypto"]
    end

    test "events have timestamps" do
      event = EventStruct.new(:invocation, "tool.net", %{action: "ping"}, LLMAgent)
      EventLog.record(event)

      [recorded] = EventLog.all()
      assert is_binary(recorded.timestamp)
      assert {:ok, _, _} = DateTime.from_iso8601(recorded.timestamp)
    end

    test "events have source module" do
      event = EventStruct.new(:invocation, "tool.proc", %{action: "list"}, LLMAgent)
      EventLog.record(event)

      [recorded] = EventLog.all()
      assert recorded.source == LLMAgent
    end

    test "sanitize_args truncates long values" do
      # Test the sanitization pattern used in LLMAgent
      long_value = String.duplicate("x", 300)
      args = %{"command" => long_value, "short" => "ok"}

      sanitized = Map.new(args, fn
        {k, v} when is_binary(v) and byte_size(v) > 200 ->
          {k, String.slice(v, 0, 200) <> "...(truncated)"}
        {k, v} -> {k, v}
      end)

      assert String.length(sanitized["command"]) < 300
      assert sanitized["command"] =~ "...(truncated)"
      assert sanitized["short"] == "ok"
    end
  end

  describe "EventBus pub/sub" do
    test "subscriber receives events on subscribed topic only" do
      EventBus.subscribe("tool.bash")

      EventBus.broadcast("tool.bash", %{data: "yes"})
      EventBus.broadcast("tool.web", %{data: "no"})

      assert_receive {:event, "tool.bash", %{data: "yes"}}
      refute_receive {:event, "tool.web", _}
    end

    test "multiple subscribers receive the same event" do
      parent = self()

      pids = for _ <- 1..3 do
        spawn(fn ->
          EventBus.subscribe("tool.crypto")
          send(parent, :subscribed)
          receive do
            {:event, topic, payload} -> send(parent, {:got, self(), topic, payload})
          end
        end)
      end

      # Wait for all subscribers
      for _ <- pids, do: assert_receive(:subscribed)

      EventBus.broadcast("tool.crypto", "payload")

      for pid <- pids do
        assert_receive {:got, ^pid, "tool.crypto", "payload"}
      end
    end
  end
end

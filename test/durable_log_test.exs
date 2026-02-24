defmodule LLMAgent.DurableLogTest do
  use ExUnit.Case, async: false

  alias LLMAgent.DurableLog
  alias Comn.Events.EventStruct

  setup do
    DurableLog.clear()
    :ok
  end

  defp make_event(type, topic, data, source \\ :test) do
    EventStruct.new(type, topic, data, source)
  end

  defp make_message_event(agent_id, role, content) do
    make_event(:message, "agent.message", %{agent_id: agent_id, role: role, content: content})
  end

  describe "record/1 and events_for/1" do
    test "persists and retrieves events for an agent" do
      event = make_event(:prompt, "agent.prompt", %{agent_id: :agent_a, content: "hi"})
      DurableLog.record(event)
      Process.sleep(20)

      events = DurableLog.events_for(:agent_a)
      assert length(events) == 1
      assert hd(events).type == :prompt
      assert hd(events).data.content == "hi"
    end

    test "events without agent_id are keyed as :system" do
      event = make_event(:system_event, "sys.boot", %{info: "started"})
      DurableLog.record(event)
      Process.sleep(20)

      assert DurableLog.events_for(:system) |> length() == 1
      assert DurableLog.events_for(:some_agent) == []
    end

    test "events are sorted by timestamp" do
      e1 = make_event(:first, "t", %{agent_id: :sorted, order: 1})
      Process.sleep(10)
      e2 = make_event(:second, "t", %{agent_id: :sorted, order: 2})

      # Insert out of order
      DurableLog.record(e2)
      DurableLog.record(e1)
      Process.sleep(20)

      events = DurableLog.events_for(:sorted)
      assert length(events) == 2
      assert Enum.at(events, 0).data.order == 1
      assert Enum.at(events, 1).data.order == 2
    end
  end

  describe "messages_for/1" do
    test "returns only agent.message events as role/content maps" do
      DurableLog.record(make_message_event(:agent_m, "system", "You are helpful."))
      DurableLog.record(make_event(:prompt, "agent.prompt", %{agent_id: :agent_m, content: "hi"}))
      DurableLog.record(make_message_event(:agent_m, "user", "hello"))
      DurableLog.record(make_message_event(:agent_m, "assistant", "hi there"))
      Process.sleep(20)

      messages = DurableLog.messages_for(:agent_m)
      assert length(messages) == 3
      assert Enum.at(messages, 0) == %{role: "system", content: "You are helpful."}
      assert Enum.at(messages, 1) == %{role: "user", content: "hello"}
      assert Enum.at(messages, 2) == %{role: "assistant", content: "hi there"}
    end

    test "returns empty list for unknown agent" do
      assert DurableLog.messages_for(:nonexistent) == []
    end
  end

  describe "events_for/2 with since:" do
    test "filters events after a given timestamp" do
      e1 = make_message_event(:since_agent, "user", "old")
      Process.sleep(10)
      cutoff = DateTime.utc_now() |> DateTime.to_iso8601()
      Process.sleep(10)
      e2 = make_message_event(:since_agent, "user", "new")

      DurableLog.record(e1)
      DurableLog.record(e2)
      Process.sleep(20)

      events = DurableLog.events_for(:since_agent, since: cutoff)
      assert length(events) == 1
      assert hd(events).data.content == "new"
    end
  end

  describe "two agents get isolated streams" do
    test "events are isolated per agent_id" do
      DurableLog.record(make_message_event(:iso_a, "user", "from a"))
      DurableLog.record(make_message_event(:iso_b, "user", "from b"))
      Process.sleep(20)

      assert DurableLog.messages_for(:iso_a) == [%{role: "user", content: "from a"}]
      assert DurableLog.messages_for(:iso_b) == [%{role: "user", content: "from b"}]
    end
  end

  describe "clear/1 and clear/0" do
    test "clear/1 removes events for one agent only" do
      DurableLog.record(make_message_event(:clear_a, "user", "a"))
      DurableLog.record(make_message_event(:clear_b, "user", "b"))
      Process.sleep(20)

      DurableLog.clear(:clear_a)
      assert DurableLog.messages_for(:clear_a) == []
      assert DurableLog.messages_for(:clear_b) == [%{role: "user", content: "b"}]
    end

    test "clear/0 removes all events" do
      DurableLog.record(make_message_event(:all_a, "user", "a"))
      DurableLog.record(make_message_event(:all_b, "user", "b"))
      Process.sleep(20)

      DurableLog.clear()
      assert DurableLog.messages_for(:all_a) == []
      assert DurableLog.messages_for(:all_b) == []
    end
  end

  describe "DETS persistence" do
    test "events survive DurableLog GenServer restart" do
      DurableLog.record(make_message_event(:persist_test, "user", "durable"))
      Process.sleep(20)

      # Force sync and let supervisor restart
      GenServer.stop(DurableLog)
      Process.sleep(100)

      messages = DurableLog.messages_for(:persist_test)
      assert length(messages) == 1
      assert hd(messages).content == "durable"
    end
  end
end

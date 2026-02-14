defmodule LLMAgentTest do
  use ExUnit.Case, async: false

  alias LLMAgent.EventLog
  setup do
    EventLog.clear()
    :ok
  end

  defp start_agent(name, opts \\ []) do
    {:ok, pid} = LLMAgent.start_link([{:name, name} | opts])
    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop({:global, name})
    end)
    pid
  end

  defp get_state(name) do
    :sys.get_state({:global, name})
  end

  defp simulate_llm_response(pid, content) do
    # Simulate an LLM response arriving as a task result.
    # We create a fake ref since handle_info demonitors it.
    ref = make_ref()
    send(pid, {ref, {:ok, %Req.Response{status: 200, body: %{"choices" => [%{"message" => %{"content" => content}}]}}}})
    # Give the GenServer a moment to process
    Process.sleep(50)
  end

  defp simulate_llm_error(pid, reason) do
    ref = make_ref()
    send(pid, {ref, {:error, reason}})
    Process.sleep(50)
  end

  ## Tests

  describe "init/1" do
    test "starts with default role" do
      pid = start_agent(:init_default)
      state = get_state(:init_default)

      assert state.role == :default
      assert state.model == "gpt-4"
      assert Process.alive?(pid)
    end

    test "starts with sysadmin role" do
      pid = start_agent(:init_sysadmin, role: :sysadmin)
      state = get_state(:init_sysadmin)

      assert state.role == :sysadmin
      assert Process.alive?(pid)
    end

    test "starts with custom model and api_host" do
      pid = start_agent(:init_custom, model: "llama3", api_host: "http://localhost:11434")
      state = get_state(:init_custom)

      assert state.model == "llama3"
      assert state.api_host == "http://localhost:11434"
      assert Process.alive?(pid)
    end
  end

  describe "role prompts in history" do
    test "default role loads default prompt" do
      start_agent(:prompt_default)
      state = get_state(:prompt_default)

      [system_msg | _] = state.history
      assert system_msg.role == "system"
      assert system_msg.content == "You are a helpful assistant."
    end

    test "sysadmin role loads sysadmin prompt" do
      start_agent(:prompt_sysadmin, role: :sysadmin)
      state = get_state(:prompt_sysadmin)

      [system_msg | _] = state.history
      assert system_msg.role == "system"
      assert system_msg.content =~ "Linux system administrator"
      assert system_msg.content =~ "Available Tools"
    end
  end

  describe "history accumulation" do
    test "prompt appends user message to history" do
      _pid = start_agent(:history_prompt)

      # prompt/2 calls GenServer.call which spawns a task (will fail to connect, that's ok)
      LLMAgent.prompt({:global, :history_prompt}, "hello")
      state = get_state(:history_prompt)

      assert length(state.history) == 2
      assert Enum.at(state.history, 1) == %{role: "user", content: "hello"}
    end

    test "non-tool LLM response appends assistant message" do
      pid = start_agent(:history_response)

      # Send a non-tool-call response
      simulate_llm_response(pid, "I'm a helpful response")
      state = get_state(:history_response)

      assert length(state.history) == 2
      assert Enum.at(state.history, 1) == %{role: "assistant", content: "I'm a helpful response"}
    end

    test "tool call response appends assistant + function messages" do
      pid = start_agent(:history_tool)

      tool_json = Jason.encode!(%{
        "tool" => "bash",
        "action" => "exec",
        "args" => %{"command" => "echo hi"}
      })

      simulate_llm_response(pid, tool_json)
      state = get_state(:history_tool)

      # Should have: system, assistant (tool json), function (result)
      # Then it sends {:prompt, followup} to itself, which adds another user message
      assert length(state.history) >= 3

      assistant_msg = Enum.at(state.history, 1)
      assert assistant_msg.role == "assistant"
      assert assistant_msg.content == tool_json

      function_msg = Enum.at(state.history, 2)
      assert function_msg.role == "function"
    end
  end

  describe "tool dispatch" do
    test "dispatches bash tool correctly" do
      pid = start_agent(:dispatch_bash)

      tool_json = Jason.encode!(%{
        "tool" => "bash",
        "action" => "exec",
        "args" => %{"command" => "echo dispatched"}
      })

      simulate_llm_response(pid, tool_json)
      state = get_state(:dispatch_bash)

      function_msg = Enum.find(state.history, &(&1.role == "function"))
      assert function_msg != nil
      assert function_msg.content =~ "dispatched"
    end

    test "dispatches crypto tool correctly" do
      pid = start_agent(:dispatch_crypto)

      tool_json = Jason.encode!(%{
        "tool" => "crypto",
        "action" => "sha256",
        "args" => %{"data" => "test"}
      })

      simulate_llm_response(pid, tool_json)
      state = get_state(:dispatch_crypto)

      function_msg = Enum.find(state.history, &(&1.role == "function"))
      assert function_msg != nil
      # SHA256 of "test" in hex
      assert function_msg.content =~ "9f86d08"
    end

    test "invalid tool returns error in function message" do
      pid = start_agent(:dispatch_invalid)

      tool_json = Jason.encode!(%{
        "tool" => "nonexistent_tool",
        "action" => "do_thing",
        "args" => %{}
      })

      simulate_llm_response(pid, tool_json)
      state = get_state(:dispatch_invalid)

      function_msg = Enum.find(state.history, &(&1.role == "function"))
      assert function_msg != nil
      assert function_msg.content =~ "Tool Error"
    end

    test "tool failure returns error message for LLM retry" do
      pid = start_agent(:dispatch_fail)

      tool_json = Jason.encode!(%{
        "tool" => "bash",
        "action" => "exec",
        "args" => %{"command" => "exit 1"}
      })

      simulate_llm_response(pid, tool_json)
      state = get_state(:dispatch_fail)

      function_msg = Enum.find(state.history, &(&1.role == "function"))
      assert function_msg != nil
      assert function_msg.content =~ "Tool Error"
    end
  end

  describe "error handling" do
    test "malformed JSON from LLM doesn't crash agent" do
      pid = start_agent(:error_malformed)

      simulate_llm_response(pid, "this is not json at all")
      assert Process.alive?(pid)

      state = get_state(:error_malformed)
      # Should be treated as not_a_tool_call, appended as assistant message
      assistant_msg = Enum.at(state.history, 1)
      assert assistant_msg.role == "assistant"
      assert assistant_msg.content == "this is not json at all"
    end

    test "partial tool JSON doesn't crash agent" do
      pid = start_agent(:error_partial_json)

      simulate_llm_response(pid, ~s({"tool": "bash"}))
      assert Process.alive?(pid)

      # Missing "action" and "args" — treated as not_a_tool_call
      state = get_state(:error_partial_json)
      assert Enum.at(state.history, 1).role == "assistant"
    end

    test "LLM request failure doesn't crash agent" do
      pid = start_agent(:error_llm_fail)

      simulate_llm_error(pid, :connection_refused)
      assert Process.alive?(pid)

      # State should be unchanged (no new messages)
      state = get_state(:error_llm_fail)
      assert length(state.history) == 1
    end

    test "LLM request failure emits agent.error event" do
      pid = start_agent(:error_event)

      simulate_llm_error(pid, :timeout)

      events = EventLog.for_topic("agent.error")
      assert length(events) == 1
      assert hd(events).type == :error
      assert hd(events).data.source == :llm_request
    end
  end

  describe "event emission" do
    test "tool invocation produces events in EventLog" do
      pid = start_agent(:events_tool)

      tool_json = Jason.encode!(%{
        "tool" => "bash",
        "action" => "exec",
        "args" => %{"command" => "echo event_test"}
      })

      simulate_llm_response(pid, tool_json)

      # Should have: agent.llm_response, agent.tool_dispatch, tool.bash
      llm_events = EventLog.for_topic("agent.llm_response")
      assert length(llm_events) >= 1
      assert hd(llm_events).data.is_tool_call == true

      dispatch_events = EventLog.for_topic("agent.tool_dispatch")
      assert length(dispatch_events) >= 1
      assert hd(dispatch_events).data.tool == :bash
      assert hd(dispatch_events).data.action == "exec"

      tool_events = EventLog.for_topic("tool.bash")
      assert length(tool_events) >= 1
      assert hd(tool_events).type == :invocation
      assert hd(tool_events).data.result == :ok
      assert is_integer(hd(tool_events).data.duration_ms)
    end

    test "non-tool response emits llm_response event only" do
      pid = start_agent(:events_plain)

      simulate_llm_response(pid, "just a plain response")

      llm_events = EventLog.for_topic("agent.llm_response")
      assert length(llm_events) == 1
      assert hd(llm_events).data.is_tool_call == false

      # No tool events
      assert EventLog.for_type(:invocation) == []
      assert EventLog.for_topic("agent.tool_dispatch") == []
    end

    test "failed tool emits invocation event with error result" do
      pid = start_agent(:events_fail)

      tool_json = Jason.encode!(%{
        "tool" => "bash",
        "action" => "exec",
        "args" => %{"command" => "exit 99"}
      })

      simulate_llm_response(pid, tool_json)

      tool_events = EventLog.for_topic("tool.bash")
      assert length(tool_events) >= 1
      assert hd(tool_events).data.result == :error
    end

    test "all events have timestamps and source" do
      pid = start_agent(:events_meta)

      simulate_llm_response(pid, "check metadata")

      events = EventLog.all()
      assert length(events) > 0

      for event <- events do
        assert is_binary(event.timestamp)
        assert {:ok, _, _} = DateTime.from_iso8601(event.timestamp)
        assert event.source == LLMAgent
      end
    end
  end
end

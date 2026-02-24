defmodule LLMAgent.AgentLifecycleTest do
  @moduledoc """
  Tests for agent lifecycle: context propagation, multi-turn tool loops,
  stop/restart, concurrent agents, and event ordering.
  """
  use ExUnit.Case, async: false

  alias LLMAgent.EventLog
  alias LLMAgent.EventBus
  alias Comn.Events.EventStruct

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
    ref = make_ref()
    send(pid, {ref, {:ok, content}})
    Process.sleep(50)
  end

  defp simulate_llm_error(pid, reason) do
    ref = make_ref()
    send(pid, {ref, {:error, reason}})
    Process.sleep(50)
  end

  defp tool_json(tool, action, args) do
    Jason.encode!(%{"tool" => tool, "action" => action, "args" => args})
  end

  # --- Context propagation ---

  describe "context propagation" do
    test "prompt sets context and enriches prompt event" do
      EventBus.subscribe("agent.prompt")
      _pid = start_agent(:ctx_prompt)

      LLMAgent.prompt({:global, :ctx_prompt}, "test context")

      assert_receive {:event, "agent.prompt", %EventStruct{} = evt}
      assert evt.data.role == :default
      assert evt.data.content == "test context"
      assert is_map(evt.data.context)
      assert evt.data.context.request_id =~ "req_"
      assert evt.data.context.trace_id =~ "trace_"
    end

    test "tool dispatch events carry context from prompt" do
      EventBus.subscribe("tool.bash")
      pid = start_agent(:ctx_dispatch)

      LLMAgent.prompt({:global, :ctx_dispatch}, "run something")
      simulate_llm_response(pid, tool_json("bash", "exec", %{"command" => "echo ctx"}))

      assert_receive {:event, "tool.bash", %EventStruct{} = evt}
      assert evt.data.context.request_id =~ "req_"
      assert evt.data.context.trace_id =~ "trace_"
    end

    test "each prompt gets a unique request_id" do
      EventBus.subscribe("agent.prompt")
      pid = start_agent(:ctx_unique)

      LLMAgent.prompt({:global, :ctx_unique}, "first")
      assert_receive {:event, "agent.prompt", %EventStruct{} = evt1}

      # The tool loop followup also triggers do_prompt, which creates a new request_id
      simulate_llm_response(pid, tool_json("bash", "exec", %{"command" => "echo one"}))
      # Wait for followup prompt
      Process.sleep(100)
      assert_receive {:event, "agent.prompt", %EventStruct{} = evt2}

      assert evt1.data.context.request_id != evt2.data.context.request_id
    end
  end

  # --- Multi-turn tool loop ---

  describe "multi-turn tool loop" do
    test "tool result is fed back as followup prompt" do
      pid = start_agent(:loop_followup)

      # First: user sends prompt (via call, adds user msg, spawns task)
      LLMAgent.prompt({:global, :loop_followup}, "do a thing")

      # Simulate LLM responding with a tool call
      simulate_llm_response(pid, tool_json("bash", "exec", %{"command" => "echo step1"}))

      # After tool dispatch, the agent sends {:prompt, followup} to itself.
      # That appends a "user" message with the tool result and spawns another LLM task.
      # Give it time to process the internal message.
      Process.sleep(100)

      state = get_state(:loop_followup)

      # History: system, user("do a thing"), assistant(tool_json), function(result), user(followup)
      assert length(state.history) >= 5
      roles = Enum.map(state.history, & &1.role)
      assert Enum.at(roles, 0) == "system"
      assert Enum.at(roles, 1) == "user"
      assert Enum.at(roles, 2) == "assistant"
      assert Enum.at(roles, 3) == "function"
      assert Enum.at(roles, 4) == "user"
    end

    test "two sequential tool calls accumulate correct history" do
      pid = start_agent(:loop_two_tools)

      LLMAgent.prompt({:global, :loop_two_tools}, "multi step")

      # First tool call
      simulate_llm_response(pid, tool_json("bash", "exec", %{"command" => "echo first"}))
      Process.sleep(100)

      # Second tool call (LLM responds to followup with another tool call)
      simulate_llm_response(pid, tool_json("bash", "exec", %{"command" => "echo second"}))
      Process.sleep(100)

      state = get_state(:loop_two_tools)

      function_msgs = Enum.filter(state.history, &(&1.role == "function"))
      assert length(function_msgs) == 2

      assert Enum.at(function_msgs, 0).content =~ "first"
      assert Enum.at(function_msgs, 1).content =~ "second"
    end

    test "tool loop terminates when LLM gives non-tool response" do
      pid = start_agent(:loop_terminate)

      LLMAgent.prompt({:global, :loop_terminate}, "go")

      # Tool call
      simulate_llm_response(pid, tool_json("bash", "exec", %{"command" => "echo work"}))
      Process.sleep(100)

      # Non-tool response ends the loop
      simulate_llm_response(pid, "All done, here are your results.")
      Process.sleep(50)

      state = get_state(:loop_terminate)

      last_msg = List.last(state.history)
      assert last_msg.role == "assistant"
      assert last_msg.content == "All done, here are your results."
    end
  end

  # --- Agent stop/restart ---

  describe "agent stop and restart" do
    test "agent can be stopped and restarted with same name" do
      pid1 = start_agent(:restart_test)
      assert Process.alive?(pid1)

      GenServer.stop({:global, :restart_test})
      refute Process.alive?(pid1)

      # Restart with same name — remove on_exit from first start
      {:ok, pid2} = LLMAgent.start_link(name: :restart_test)
      on_exit(fn ->
        if Process.alive?(pid2), do: GenServer.stop({:global, :restart_test})
      end)

      assert Process.alive?(pid2)
      assert pid1 != pid2

      # Fresh state
      state = get_state(:restart_test)
      assert length(state.history) == 1
      assert hd(state.history).role == "system"
    end

    test "agent survives rapid prompt after restart" do
      _pid1 = start_agent(:restart_prompt)
      GenServer.stop({:global, :restart_prompt})

      {:ok, pid2} = LLMAgent.start_link(name: :restart_prompt)
      on_exit(fn ->
        if Process.alive?(pid2), do: GenServer.stop({:global, :restart_prompt})
      end)

      LLMAgent.prompt({:global, :restart_prompt}, "after restart")
      assert Process.alive?(pid2)

      state = get_state(:restart_prompt)
      assert length(state.history) == 2
    end
  end

  # --- Concurrent agents ---

  describe "concurrent agents" do
    test "multiple agents run independently" do
      _pid_a = start_agent(:concurrent_a, role: :default)
      _pid_b = start_agent(:concurrent_b, role: :sysadmin)

      LLMAgent.prompt({:global, :concurrent_a}, "agent a prompt")
      LLMAgent.prompt({:global, :concurrent_b}, "agent b prompt")

      state_a = get_state(:concurrent_a)
      state_b = get_state(:concurrent_b)

      assert state_a.role == :default
      assert state_b.role == :sysadmin

      assert Enum.at(state_a.history, 1).content == "agent a prompt"
      assert Enum.at(state_b.history, 1).content == "agent b prompt"
    end

    test "tool dispatch on one agent doesn't affect another" do
      pid_a = start_agent(:isolated_a)
      _pid_b = start_agent(:isolated_b)

      simulate_llm_response(pid_a, tool_json("bash", "exec", %{"command" => "echo a"}))
      Process.sleep(100)

      state_a = get_state(:isolated_a)
      state_b = get_state(:isolated_b)

      assert length(state_a.history) > 1
      assert length(state_b.history) == 1
    end
  end

  # --- Event ordering ---

  describe "event ordering through lifecycle" do
    test "full tool call lifecycle emits events in order" do
      pid = start_agent(:evt_order)

      LLMAgent.prompt({:global, :evt_order}, "ordered test")
      simulate_llm_response(pid, tool_json("bash", "exec", %{"command" => "echo ordered"}))
      Process.sleep(100)

      events = EventLog.all()

      # Filter to events from this lifecycle (prompt + llm_response + tool_dispatch + invocation + followup prompt)
      topics = Enum.map(events, & &1.topic)

      # prompt comes first
      prompt_idx = Enum.find_index(topics, &(&1 == "agent.prompt"))
      # llm_response next
      llm_idx = Enum.find_index(topics, &(&1 == "agent.llm_response"))
      # tool_dispatch next
      dispatch_idx = Enum.find_index(topics, &(&1 == "agent.tool_dispatch"))
      # tool invocation last (before followup prompt)
      invocation_idx = Enum.find_index(topics, &(&1 == "tool.bash"))

      assert prompt_idx < llm_idx
      assert llm_idx < dispatch_idx
      assert dispatch_idx < invocation_idx
    end

    test "error events preserve ordering" do
      pid = start_agent(:evt_error_order)

      LLMAgent.prompt({:global, :evt_error_order}, "will error")
      simulate_llm_error(pid, :connection_refused)

      events = EventLog.all()
      topics = Enum.map(events, & &1.topic)

      prompt_idx = Enum.find_index(topics, &(&1 == "agent.prompt"))
      error_idx = Enum.find_index(topics, &(&1 == "agent.error"))

      assert prompt_idx < error_idx
    end

    test "multiple tool calls produce ordered invocation events" do
      pid = start_agent(:evt_multi)

      LLMAgent.prompt({:global, :evt_multi}, "multi")

      simulate_llm_response(pid, tool_json("bash", "exec", %{"command" => "echo one"}))
      Process.sleep(100)
      simulate_llm_response(pid, tool_json("crypto", "sha256", %{"data" => "two"}))
      Process.sleep(100)

      invocations = EventLog.for_type(:invocation)
      assert length(invocations) >= 2

      topics = Enum.map(invocations, & &1.topic)
      bash_idx = Enum.find_index(topics, &(&1 == "tool.bash"))
      crypto_idx = Enum.find_index(topics, &(&1 == "tool.crypto"))

      assert bash_idx < crypto_idx
    end
  end

  # --- Cross-tool dispatch ---

  describe "cross-tool dispatch" do
    test "file tool dispatch works through agent" do
      pid = start_agent(:dispatch_file)

      path = Path.join(System.tmp_dir!(), "agent_lifecycle_test_#{System.unique_integer([:positive])}")

      simulate_llm_response(pid, tool_json("file", "write", %{
        "path" => path, "content" => "lifecycle"
      }))

      state = get_state(:dispatch_file)
      function_msg = Enum.find(state.history, &(&1.role == "function"))
      assert function_msg.content =~ "ok"

      File.rm(path)
    end

    test "net tool dispatch works through agent" do
      pid = start_agent(:dispatch_net)

      simulate_llm_response(pid, tool_json("net", "resolve", %{"host" => "localhost"}))

      state = get_state(:dispatch_net)
      function_msg = Enum.find(state.history, &(&1.role == "function"))
      assert function_msg != nil
    end
  end

  # --- Memory persistence ---

  describe "memory persistence" do
    test "agent restores history from memory on restart" do
      name = :mem_persist_test

      # Pre-create the ETS table from the test process so it survives agent death.
      # The agent's init will call memory.init which is idempotent.
      LLMAgent.Memory.ETS.init(name)

      on_exit(fn -> LLMAgent.Memory.ETS.teardown(name) end)

      pid1 = start_agent(name)

      LLMAgent.prompt({:global, name}, "remember this")
      simulate_llm_response(pid1, "I will remember")

      state1 = get_state(name)
      assert length(state1.history) == 3

      # Stop agent (triggers terminate which persists)
      GenServer.stop({:global, name})
      refute Process.alive?(pid1)

      # Restart with same name — should restore history from ETS
      {:ok, pid2} = LLMAgent.start_link(name: name)
      on_exit(fn ->
        if Process.alive?(pid2), do: GenServer.stop({:global, name})
      end)

      state2 = get_state(name)
      assert length(state2.history) == 3
      assert Enum.at(state2.history, 1).content == "remember this"
      assert Enum.at(state2.history, 2).content == "I will remember"
    end
  end

  # --- Resilience ---

  describe "resilience" do
    test "agent survives rapid sequential prompts" do
      pid = start_agent(:rapid_prompts)

      for i <- 1..5 do
        LLMAgent.prompt({:global, :rapid_prompts}, "prompt #{i}")
      end

      assert Process.alive?(pid)
      state = get_state(:rapid_prompts)
      # system + 5 user messages
      assert length(state.history) == 6
    end

    test "agent survives interleaved responses and errors" do
      pid = start_agent(:interleaved)

      LLMAgent.prompt({:global, :interleaved}, "start")

      simulate_llm_response(pid, "response one")
      simulate_llm_error(pid, :timeout)
      simulate_llm_response(pid, "response two")
      simulate_llm_error(pid, %Req.TransportError{reason: :econnrefused})

      assert Process.alive?(pid)

      state = get_state(:interleaved)
      assistant_msgs = Enum.filter(state.history, &(&1.role == "assistant"))
      assert length(assistant_msgs) == 2
    end

    test "agent handles empty string response" do
      pid = start_agent(:empty_response)

      simulate_llm_response(pid, "")
      assert Process.alive?(pid)

      state = get_state(:empty_response)
      assert Enum.at(state.history, 1) == %{role: "assistant", content: ""}
    end
  end
end

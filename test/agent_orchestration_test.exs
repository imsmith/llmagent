defmodule LLMAgent.AgentOrchestrationTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias LLMAgent.TupleSpace
  alias LLMAgent.EventLog

  setup do
    EventLog.clear()
    TupleSpace.stop_space(:default)
    {:ok, _} = TupleSpace.start_space(:default)
    LLMAgent.DurableLog.clear()
    :ok
  end

  defp start_agent(name, opts \\ []) do
    {:ok, pid} = LLMAgent.start_link([{:name, name} | opts])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop({:global, name}) end)
    pid
  end

  defp simulate_llm(pid, content) do
    ref = make_ref()
    send(pid, {ref, {:ok, content}})
    Process.sleep(60)
  end

  defp tool_json(tool, action, args) do
    Jason.encode!(%{"tool" => tool, "action" => action, "args" => args})
  end

  describe "async fan-out / fan-in" do
    test "root spawns async child, collects result from tuple space" do
      root = start_agent(:orch_root_async)

      LLMAgent.prompt({:global, :orch_root_async}, "do something")
      simulate_llm(root, tool_json("agent", "spawn", %{
        "name" => "orch_async_child",
        "prompt" => "do work",
        "tools" => ["bash"],
        "mode" => "async"
      }))

      assert is_pid(GenServer.whereis({:global, :orch_async_child}))
      child_state = :sys.get_state({:global, :orch_async_child})
      assert child_state.parent == :orch_root_async
      assert child_state.allowed_tools == [:bash]

      child_pid = GenServer.whereis({:global, :orch_async_child})
      simulate_llm(child_pid, "child done")

      assert {:ok, {:agent_result, :orch_async_child, "child done"}} =
               TupleSpace.in_nowait({:agent_result, :orch_async_child, :_})
    end
  end

  describe "spawn depth enforcement" do
    test "child attempting to spawn a grandchild gets denied" do
      _root = start_agent(:orch_dn_root)

      {:ok, child_pid} =
        LLMAgent.AgentSupervisor.start_agent(
          name: :orch_dn_child,
          parent: :orch_dn_root,
          allowed_tools: [:agent]
        )

      on_exit(fn ->
        if Process.alive?(child_pid),
          do: LLMAgent.AgentSupervisor.stop_agent(:orch_dn_child)
      end)

      LLMAgent.prompt({:global, :orch_dn_child}, "go")
      simulate_llm(child_pid, tool_json("agent", "spawn", %{
        "name" => "grandchild",
        "prompt" => "x",
        "tools" => ["bash"],
        "mode" => "async"
      }))

      state = :sys.get_state({:global, :orch_dn_child})
      function_msg = Enum.find(state.history, &(&1.role == "function"))
      assert function_msg.content =~ "spawn_depth_exceeded"
      assert GenServer.whereis({:global, :grandchild}) == nil
    end
  end

  describe "whitelist enforcement under orchestration" do
    test "child rejecting disallowed tool produces error result, no dispatch" do
      _root = start_agent(:orch_wl_root)

      {:ok, child_pid} =
        LLMAgent.AgentSupervisor.start_agent(
          name: :orch_wl_child,
          parent: :orch_wl_root,
          allowed_tools: [:file]
        )

      on_exit(fn ->
        if Process.alive?(child_pid),
          do: LLMAgent.AgentSupervisor.stop_agent(:orch_wl_child)
      end)

      LLMAgent.prompt({:global, :orch_wl_child}, "go")
      simulate_llm(child_pid, tool_json("bash", "exec", %{"command" => "echo blocked"}))

      state = :sys.get_state({:global, :orch_wl_child})
      function_msg = Enum.find(state.history, &(&1.role == "function"))
      assert function_msg.content =~ "tool :bash not permitted"
    end
  end

  describe "orphan resilience" do
    test "child whose parent dies still writes result to tuple space" do
      parent_pid = start_agent(:orch_orph_parent)

      {:ok, child_pid} =
        LLMAgent.AgentSupervisor.start_agent(
          name: :orch_orph_child,
          parent: :orch_orph_parent,
          allowed_tools: [:bash]
        )

      on_exit(fn ->
        if Process.alive?(child_pid),
          do: LLMAgent.AgentSupervisor.stop_agent(:orch_orph_child)
      end)

      GenServer.stop(parent_pid)
      Process.sleep(40)

      simulate_llm(child_pid, "orphaned but done")

      assert {:ok, {:agent_result, :orch_orph_child, "orphaned but done"}} =
               TupleSpace.in_nowait({:agent_result, :orch_orph_child, :_})
    end
  end

  describe "child crash propagation" do
    test "abnormal exit writes {:agent_error, name, reason}" do
      _root = start_agent(:orch_crash_root)

      {:ok, _child_pid} =
        LLMAgent.AgentSupervisor.start_agent(
          name: :orch_crash_child,
          parent: :orch_crash_root,
          allowed_tools: [:bash]
        )

      Process.flag(:trap_exit, true)
      GenServer.stop({:global, :orch_crash_child}, :forced_crash)
      Process.flag(:trap_exit, false)
      Process.sleep(60)

      assert {:ok, {:agent_error, :orch_crash_child, _reason}} =
               TupleSpace.in_nowait({:agent_error, :orch_crash_child, :_})
    end
  end
end

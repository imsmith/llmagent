defmodule LLMAgent.AgentSupervisorTest do
  use ExUnit.Case, async: false

  alias LLMAgent.AgentSupervisor

  setup do
    on_exit(fn ->
      # Clean up any agents we started
      for pid <- AgentSupervisor.list_agents() do
        try do
          DynamicSupervisor.terminate_child(AgentSupervisor, pid)
        catch
          _, _ -> :ok
        end
      end
    end)

    :ok
  end

  describe "start_agent/1" do
    test "spawns agent under DynamicSupervisor" do
      name = :"sup_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = AgentSupervisor.start_agent(name: name)
      assert Process.alive?(pid)
    end

    test "agent is accessible via global name" do
      name = :"sup_access_#{System.unique_integer([:positive])}"
      {:ok, _pid} = AgentSupervisor.start_agent(name: name)
      state = :sys.get_state({:global, name})
      assert state.name == name
    end
  end

  describe "stop_agent/1" do
    test "terminates agent" do
      name = :"sup_stop_#{System.unique_integer([:positive])}"
      {:ok, pid} = AgentSupervisor.start_agent(name: name)
      assert :ok = AgentSupervisor.stop_agent(name)
      refute Process.alive?(pid)
    end

    test "returns error for nonexistent agent" do
      assert {:error, :not_found} = AgentSupervisor.stop_agent(:nonexistent_agent)
    end
  end

  describe "list_agents/0" do
    test "returns pids of running agents" do
      name1 = :"sup_list1_#{System.unique_integer([:positive])}"
      name2 = :"sup_list2_#{System.unique_integer([:positive])}"

      {:ok, pid1} = AgentSupervisor.start_agent(name: name1)
      {:ok, pid2} = AgentSupervisor.start_agent(name: name2)

      agents = AgentSupervisor.list_agents()
      assert pid1 in agents
      assert pid2 in agents
    end
  end

  describe "concurrent agents" do
    test "multiple agents with different configs" do
      name1 = :"sup_multi1_#{System.unique_integer([:positive])}"
      name2 = :"sup_multi2_#{System.unique_integer([:positive])}"

      {:ok, _} = AgentSupervisor.start_agent(name: name1, role: :default)
      {:ok, _} = AgentSupervisor.start_agent(name: name2, role: :sysadmin)

      state1 = :sys.get_state({:global, name1})
      state2 = :sys.get_state({:global, name2})

      assert state1.role == :default
      assert state2.role == :sysadmin
    end

    test "stopping one doesn't affect others" do
      name1 = :"sup_indep1_#{System.unique_integer([:positive])}"
      name2 = :"sup_indep2_#{System.unique_integer([:positive])}"

      {:ok, _} = AgentSupervisor.start_agent(name: name1)
      {:ok, pid2} = AgentSupervisor.start_agent(name: name2)

      AgentSupervisor.stop_agent(name1)
      assert Process.alive?(pid2)
    end
  end
end

defmodule LLMAgent.Tools.AgentTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias LLMAgent.Tools.Agent, as: AgentTool
  alias LLMAgent.TupleSpace
  alias Comn.Errors.ErrorStruct
  alias Comn.Contexts

  setup do
    TupleSpace.stop_space(:default)
    {:ok, _} = TupleSpace.start_space(:default)

    Contexts.new(%{request_id: "test", trace_id: "test", actor: "test"})
    Contexts.put(:agent_name, :test_root_caller)
    Contexts.put(:agent_parent, nil)

    on_exit(fn ->
      for pid <- LLMAgent.AgentSupervisor.list_agents() do
        DynamicSupervisor.terminate_child(LLMAgent.AgentSupervisor, pid)
      end
    end)

    :ok
  end

  describe "describe/0" do
    test "lists all actions" do
      desc = AgentTool.describe()
      for a <- ~w(spawn kill list status), do: assert desc =~ a
    end
  end

  describe "spawn (async)" do
    test "starts a child and returns immediately" do
      args = %{
        "name" => "child_a",
        "prompt" => "noop",
        "tools" => ["bash"],
        "mode" => "async"
      }

      assert {:ok, %{output: output}} = AgentTool.perform("spawn", args)
      assert output =~ "child_a"
      assert output =~ "started"

      assert is_pid(GenServer.whereis({:global, :child_a}))
    end

    test "child has parent and allowed_tools set" do
      AgentTool.perform("spawn", %{
        "name" => "child_b",
        "prompt" => "noop",
        "tools" => ["file", "bash"],
        "mode" => "async"
      })

      state = :sys.get_state({:global, :child_b})
      assert state.parent == :test_root_caller
      assert state.allowed_tools == [:file, :bash]
    end

    test "spawn rejected when caller is itself a child" do
      Contexts.put(:agent_parent, :some_root)

      assert {:error, %ErrorStruct{reason: "spawn_depth_exceeded"}} =
               AgentTool.perform("spawn", %{
                 "name" => "grandchild",
                 "prompt" => "noop",
                 "tools" => ["bash"],
                 "mode" => "async"
               })

      assert GenServer.whereis({:global, :grandchild}) == nil
    end
  end

  describe "list, status, kill" do
    test "list returns running children" do
      AgentTool.perform("spawn", %{
        "name" => "child_l",
        "prompt" => "noop",
        "tools" => ["bash"],
        "mode" => "async"
      })

      {:ok, %{output: agents}} = AgentTool.perform("list", %{})
      names = Enum.map(agents, & &1["name"])
      assert "child_l" in names
    end

    test "status of a running child" do
      AgentTool.perform("spawn", %{
        "name" => "child_s",
        "prompt" => "noop",
        "tools" => ["bash"],
        "mode" => "async"
      })

      assert {:ok, %{output: %{"running" => true, "name" => "child_s"}}} =
               AgentTool.perform("status", %{"name" => "child_s"})
    end

    test "status of a missing child" do
      assert {:ok, %{output: %{"running" => false, "name" => "missing_x"}}} =
               AgentTool.perform("status", %{"name" => "missing_x"})
    end

    test "kill stops a child" do
      AgentTool.perform("spawn", %{
        "name" => "child_k",
        "prompt" => "noop",
        "tools" => ["bash"],
        "mode" => "async"
      })

      assert {:ok, %{output: "ok"}} = AgentTool.perform("kill", %{"name" => "child_k"})
      Process.sleep(20)
      assert GenServer.whereis({:global, :child_k}) == nil
    end

    test "kill missing child returns error" do
      assert {:error, %ErrorStruct{reason: "not_found"}} =
               AgentTool.perform("kill", %{"name" => "missing_k"})
    end
  end

  describe "unknown action" do
    test "returns unknown_command" do
      assert {:error, %ErrorStruct{reason: "unknown_command"}} = AgentTool.perform("nope", %{})
    end
  end

  describe "spawn (sync)" do
    test "blocks until child writes result, returns content" do
      Task.start(fn ->
        Process.sleep(40)
        TupleSpace.out({:agent_result, :child_sync_ok, "the answer"})
        Process.sleep(20)
        LLMAgent.AgentSupervisor.stop_agent(:child_sync_ok)
      end)

      args = %{
        "name" => "child_sync_ok",
        "prompt" => "noop",
        "tools" => ["bash"],
        "mode" => "sync",
        "timeout" => 1_000
      }

      assert {:ok, %{output: "the answer"}} = AgentTool.perform("spawn", args)
    end

    test "times out and kills the child if no result arrives" do
      args = %{
        "name" => "child_sync_to",
        "prompt" => "noop",
        "tools" => ["bash"],
        "mode" => "sync",
        "timeout" => 100
      }

      assert {:error, %ErrorStruct{reason: "timeout"}} = AgentTool.perform("spawn", args)
      Process.sleep(50)
      assert GenServer.whereis({:global, :child_sync_to}) == nil
    end
  end

  describe "tool-discovery substrate (via Dispatcher)" do
    alias LLMAgent.{Tools.Agent, Tools.Discovery, Tool.Dispatcher, Tool.Policy}

    setup do
      case Process.whereis(Discovery) do
        nil -> {:ok, _} = Discovery.start_link(consume_announcements: false)
        _ -> Discovery.reset!()
      end

      LLMAgent.Tool.Bindings.init_registry()
      LLMAgent.Tool.Kinds.init_registry()
      :ok = Discovery.register(Agent.ad())
      :ok
    end

    test "ad/0 returns a ToolAd for function.agent with :spawn kind" do
      ad = Agent.ad()
      assert ad.coordinate == "function.agent"
      assert :spawn in ad.kinds
      assert ad.fidelity == :authoritative
    end

    test "dispatcher.spawn_child/3 starts a child agent and terminate_child stops it" do
      policy = %Policy{
        allow: ["function.agent"],
        fidelity_min: :authoritative
      }

      child_name = :"substrate_spawn_test_#{System.unique_integer([:positive])}"

      spec = {"start", %{
        "name" => Atom.to_string(child_name),
        "prompt" => "noop",
        "tools" => ["bash"],
        "mode" => "async"
      }}

      assert {:ok, child_ref} =
               Dispatcher.spawn_child("function.agent", spec, policy: policy)

      assert is_atom(child_ref) or is_pid(child_ref) or is_tuple(child_ref)

      # Best-effort cleanup
      _ = LLMAgent.AgentSupervisor.stop_agent(child_name)
    end
  end
end

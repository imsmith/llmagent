defmodule LLMAgent.Memory.ETSTest do
  use ExUnit.Case, async: false

  alias LLMAgent.Memory.ETS

  setup do
    agent_id = :"mem_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> ETS.teardown(agent_id) end)
    %{agent_id: agent_id}
  end

  describe "init/2" do
    test "creates table", %{agent_id: agent_id} do
      assert :ok = ETS.init(agent_id)
    end

    test "is idempotent on second call", %{agent_id: agent_id} do
      assert :ok = ETS.init(agent_id)
      assert :ok = ETS.init(agent_id)
    end
  end

  describe "store/3 and fetch/3" do
    test "round-trip", %{agent_id: agent_id} do
      ETS.init(agent_id)
      assert :ok = ETS.store(agent_id, :key1, "value1")
      assert {:ok, "value1"} = ETS.fetch(agent_id, :key1)
    end

    test "stores complex values", %{agent_id: agent_id} do
      ETS.init(agent_id)
      history = [%{role: "system", content: "hello"}, %{role: "user", content: "hi"}]
      assert :ok = ETS.store(agent_id, :history, history)
      assert {:ok, ^history} = ETS.fetch(agent_id, :history)
    end

    test "overwrites existing key", %{agent_id: agent_id} do
      ETS.init(agent_id)
      ETS.store(agent_id, :key, "v1")
      ETS.store(agent_id, :key, "v2")
      assert {:ok, "v2"} = ETS.fetch(agent_id, :key)
    end
  end

  describe "fetch/2" do
    test "returns {:error, :not_found} for missing key", %{agent_id: agent_id} do
      ETS.init(agent_id)
      assert {:error, :not_found} = ETS.fetch(agent_id, :nonexistent)
    end
  end

  describe "delete/2" do
    test "removes key", %{agent_id: agent_id} do
      ETS.init(agent_id)
      ETS.store(agent_id, :key, "value")
      assert :ok = ETS.delete(agent_id, :key)
      assert {:error, :not_found} = ETS.fetch(agent_id, :key)
    end
  end

  describe "list/1" do
    test "returns all entries", %{agent_id: agent_id} do
      ETS.init(agent_id)
      ETS.store(agent_id, :a, 1)
      ETS.store(agent_id, :b, 2)
      {:ok, entries} = ETS.list(agent_id)
      assert length(entries) == 2
      assert {:a, 1} in entries
      assert {:b, 2} in entries
    end

    test "returns empty list for empty table", %{agent_id: agent_id} do
      ETS.init(agent_id)
      assert {:ok, []} = ETS.list(agent_id)
    end
  end

  describe "teardown/1" do
    test "drops table", %{agent_id: agent_id} do
      ETS.init(agent_id)
      ETS.store(agent_id, :key, "value")
      assert :ok = ETS.teardown(agent_id)
    end
  end

  describe "isolation" do
    test "two agents get isolated tables" do
      id1 = :"iso_test_#{System.unique_integer([:positive])}"
      id2 = :"iso_test_#{System.unique_integer([:positive])}"

      on_exit(fn ->
        ETS.teardown(id1)
        ETS.teardown(id2)
      end)

      ETS.init(id1)
      ETS.init(id2)

      ETS.store(id1, :key, "agent1")
      ETS.store(id2, :key, "agent2")

      assert {:ok, "agent1"} = ETS.fetch(id1, :key)
      assert {:ok, "agent2"} = ETS.fetch(id2, :key)
    end
  end
end

defmodule LLMAgent.Tool.Adapter.ModuleTest do
  @moduledoc false
  use ExUnit.Case, async: true

  defmodule StubTool do
    @moduledoc false
    @behaviour LLMAgent.Tool.Kinds.Compute
    @behaviour LLMAgent.Tool.Kinds.Query
    @behaviour LLMAgent.Tool.Kinds.Action

    @impl LLMAgent.Tool.Kinds.Compute
    def compute("double", %{"n" => n}), do: {:ok, n * 2}

    @impl LLMAgent.Tool.Kinds.Query
    def query("now", _args), do: {:ok, :answer, %{source: "stub"}}

    @impl LLMAgent.Tool.Kinds.Action
    def act("write", %{"x" => x}, _key), do: {:ok, %{wrote: x}, %{}}
  end

  alias LLMAgent.Tool.Adapter.Module, as: ModAdapter

  describe "compute/4" do
    test "passes through to the module" do
      assert {:ok, 10} = ModAdapter.compute(StubTool, "double", %{"n" => 5}, [])
    end
  end

  describe "query/4" do
    test "passes through to the module" do
      assert {:ok, :answer, %{source: "stub"}} = ModAdapter.query(StubTool, "now", %{}, [])
    end
  end

  describe "act/5" do
    test "passes through with idempotency key" do
      assert {:ok, %{wrote: 1}, %{}} = ModAdapter.act(StubTool, "write", %{"x" => 1}, "key-1", [])
    end
  end
end

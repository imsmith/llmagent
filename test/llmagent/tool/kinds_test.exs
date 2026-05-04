defmodule LLMAgent.Tool.KindsTest do
  @moduledoc false
  use ExUnit.Case, async: false   # mutates persistent_term

  alias LLMAgent.Tool.Kinds

  setup do
    Kinds.init_registry()
    :ok
  end

  describe "init_registry/0" do
    test "seeds the canonical six" do
      assert Kinds.list_kinds() |> Enum.sort() ==
               [:action, :compute, :coordinate, :query, :spawn, :stream]
    end

    test "kind atoms map to behaviour modules" do
      assert {:ok, LLMAgent.Tool.Kinds.Compute} = Kinds.behaviour_for(:compute)
      assert {:ok, LLMAgent.Tool.Kinds.SpawnKind} = Kinds.behaviour_for(:spawn)
    end
  end

  describe "register_kind/2" do
    test "adds a new kind" do
      defmodule MyKindBehaviour do
        @moduledoc false
        @doc "Test callback."
        @callback do_thing() :: :ok
      end

      :ok = Kinds.register_kind(:my_kind, MyKindBehaviour)
      assert {:ok, MyKindBehaviour} = Kinds.behaviour_for(:my_kind)

      Kinds.unregister_kind(:my_kind)
    end

    test "rejects non-module values" do
      assert {:error, :invalid_behaviour} = Kinds.register_kind(:bogus, "not a module")
    end
  end

  describe "behaviour_for/1" do
    test "returns :not_found for unknown kinds" do
      assert {:error, :not_found} = Kinds.behaviour_for(:nope)
    end
  end
end

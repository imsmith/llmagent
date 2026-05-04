defmodule LLMAgent.Tool.AdapterTest do
  @moduledoc false
  use ExUnit.Case, async: true

  describe "behaviour callbacks" do
    test "all kind callbacks are declared" do
      callbacks = LLMAgent.Tool.Adapter.behaviour_info(:callbacks)

      expected = [
        query: 4, act: 5, subscribe: 5, unsubscribe: 3, compute: 4,
        participate: 5, leave: 3, spawn_child: 4, child_status: 3,
        terminate_child: 4
      ]

      for {fun, arity} <- expected do
        assert {fun, arity} in callbacks,
               "Adapter missing callback #{fun}/#{arity}"
      end
    end

    test "all callbacks are optional" do
      optional = LLMAgent.Tool.Adapter.behaviour_info(:optional_callbacks) |> Enum.sort()

      expected = [
        act: 5, child_status: 3, compute: 4, leave: 3, participate: 5,
        query: 4, spawn_child: 4, subscribe: 5, terminate_child: 4, unsubscribe: 3
      ] |> Enum.sort()

      assert optional == expected
    end
  end
end

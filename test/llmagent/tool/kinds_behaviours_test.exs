defmodule LLMAgent.Tool.KindsBehavioursTest do
  @moduledoc "Tests that verify all six kind behaviours declare their expected callbacks."

  use ExUnit.Case, async: true

  @cases [
    {LLMAgent.Tool.Kinds.Query, [query: 2]},
    {LLMAgent.Tool.Kinds.Action, [act: 3]},
    {LLMAgent.Tool.Kinds.Stream, [subscribe: 3, unsubscribe: 1]},
    {LLMAgent.Tool.Kinds.Compute, [compute: 2]},
    {LLMAgent.Tool.Kinds.Coordinate, [participate: 3, leave: 1]},
    {LLMAgent.Tool.Kinds.SpawnKind, [spawn_child: 2, child_status: 1, terminate_child: 2]}
  ]

  for {mod, expected_callbacks} <- @cases do
    test "#{inspect(mod)} declares #{inspect(expected_callbacks)}" do
      callbacks = unquote(mod).behaviour_info(:callbacks)

      for {fun, arity} <- unquote(Macro.escape(expected_callbacks)) do
        assert {fun, arity} in callbacks,
               "#{unquote(inspect(mod))} missing callback #{fun}/#{arity}"
      end
    end
  end
end

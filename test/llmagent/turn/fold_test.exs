defmodule LLMAgent.Turn.FoldTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias LLMAgent.Turn.Fold

  defp fold(events), do: events |> Enum.reduce(Fold.new(), &Fold.step(&2, &1)) |> Fold.result()

  @usage %{input_tokens: 7, output_tokens: 3}

  test "text only folds deltas into one text block" do
    events = [
      {:start, %{model: "m1"}},
      {:block_start, 0, :text},
      {:text_delta, 0, "hello "},
      {:text_delta, 0, "there"},
      {:block_stop, 0},
      {:stop, :end_turn, @usage}
    ]

    assert {:ok, result} = fold(events)
    assert result.model == "m1"
    assert result.stop_reason == :end_turn
    assert result.usage == @usage
    assert result.message.role == :assistant
    assert [%{type: :text, text: "hello there"}] = result.message.content
  end

  test "reasoning then two tool calls fold in index order with decoded input" do
    events = [
      {:start, %{model: "m1"}},
      {:block_start, 0, :reasoning},
      {:reasoning_delta, 0, "think"},
      {:block_stop, 0},
      {:block_start, 1, {:tool_call, "id_a", "get_weather"}},
      {:tool_args_delta, 1, ~s({"city":)},
      {:tool_args_delta, 1, ~s("Paris"})},
      {:block_stop, 1},
      {:block_start, 2, {:tool_call, "id_b", "get_weather"}},
      {:tool_args_delta, 2, ~s({"city":"Oslo"})},
      {:block_stop, 2},
      {:stop, :tool_use, @usage}
    ]

    assert {:ok, %{message: %{content: [reasoning, a, b]}, stop_reason: :tool_use}} = fold(events)
    assert %{type: :reasoning, text: "think"} = reasoning

    assert %{type: :tool_call, id: "id_a", name: "get_weather", input: %{"city" => "Paris"}} = a
    assert a.input_json == ~s({"city":"Paris"})
    assert %{type: :tool_call, id: "id_b", input: %{"city" => "Oslo"}} = b
  end

  test "arguments that are not valid JSON keep the raw text and do not fail the fold" do
    events = [
      {:start, %{model: nil}},
      {:block_start, 0, {:tool_call, "id_a", "get_weather"}},
      {:tool_args_delta, 0, ~s({"city":)},
      {:block_stop, 0},
      {:stop, :tool_use, @usage}
    ]

    assert {:ok, %{message: %{content: [block]}}} = fold(events)
    assert block.input == nil
    assert block.input_json == ~s({"city":)
  end

  test "a tool call with no argument deltas has empty input" do
    events = [
      {:start, %{model: nil}},
      {:block_start, 0, {:tool_call, "id_a", "ping"}},
      {:block_stop, 0},
      {:stop, :tool_use, @usage}
    ]

    assert {:ok, %{message: %{content: [block]}}} = fold(events)
    assert block.input_json == ""
    assert block.input == %{}
  end

  test "an error event anywhere makes the result an error" do
    events = [
      {:start, %{model: nil}},
      {:block_start, 0, :text},
      {:text_delta, 0, "partial"},
      {:error, :boom},
      {:stop, :end_turn, @usage}
    ]

    assert {:error, :boom} = fold(events)
  end

  test "events ending without a stop are incomplete" do
    events = [{:start, %{model: nil}}, {:block_start, 0, :text}, {:text_delta, 0, "x"}]
    assert {:error, :incomplete} = fold(events)
  end
end

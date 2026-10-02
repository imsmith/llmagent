defmodule LLMAgent.Turn.Fold do
  @moduledoc """
  Reduces a stream of canonical events (`t:LLMAgent.Turn.event/0`) to the final
  assistant message.

  This is the single path by which a non-streaming response and a turn's
  provenance are produced, so a streamed turn and its folded form cannot
  disagree.

  ## Examples

      iex> alias LLMAgent.Turn.Fold
      iex> events = [
      ...>   {:start, %{model: "m"}},
      ...>   {:block_start, 0, :text},
      ...>   {:text_delta, 0, "hi"},
      ...>   {:block_stop, 0},
      ...>   {:stop, :end_turn, %{input_tokens: 1, output_tokens: 1}}
      ...> ]
      iex> {:ok, result} = events |> Enum.reduce(Fold.new(), &Fold.step(&2, &1)) |> Fold.result()
      iex> hd(result.message.content).text
      "hi"
  """

  alias LLMAgent.Turn

  @enforce_keys []
  defstruct model: nil, blocks: %{}, stop: nil, error: nil

  @opaque t :: %__MODULE__{}

  @type result :: %{
          message: Turn.message(),
          model: String.t() | nil,
          stop_reason: Turn.stop_reason(),
          usage: Turn.usage()
        }

  @doc "A fresh fold state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Absorb one canonical event."
  @spec step(t(), Turn.event()) :: t()
  def step(%__MODULE__{} = state, {:start, %{model: model}}), do: %{state | model: model}

  def step(state, {:block_start, index, :text}),
    do: put_block(state, index, %{type: :text, text: "", extra: %{}})

  def step(state, {:block_start, index, :reasoning}),
    do: put_block(state, index, %{type: :reasoning, text: "", extra: %{}})

  def step(state, {:block_start, index, {:tool_call, id, name}}),
    do: put_block(state, index, %{type: :tool_call, id: id, name: name, input_json: "", extra: %{}})

  def step(state, {:text_delta, index, text}), do: append(state, index, :text, text)
  def step(state, {:reasoning_delta, index, text}), do: append(state, index, :text, text)
  def step(state, {:tool_args_delta, index, json}), do: append(state, index, :input_json, json)
  def step(state, {:block_stop, _index}), do: state
  def step(state, {:stop, reason, usage}), do: %{state | stop: {reason, usage}}
  def step(%__MODULE__{error: nil} = state, {:error, reason}), do: %{state | error: {:error, reason}}
  def step(state, {:error, _reason}), do: state

  @doc """
  The folded turn, or the reason there is none: the first `:error` event seen,
  or `:incomplete` when the events ended without a `:stop`.
  """
  @spec result(t()) :: {:ok, result()} | {:error, Turn.error_reason()}
  def result(%__MODULE__{error: {:error, reason}}), do: {:error, reason}
  def result(%__MODULE__{stop: nil}), do: {:error, :incomplete}

  def result(%__MODULE__{stop: {reason, usage}} = state) do
    content =
      state.blocks
      |> Enum.sort_by(fn {index, _block} -> index end)
      |> Enum.map(fn {_index, block} -> finish(block) end)

    {:ok,
     %{
       message: %{role: :assistant, content: content, extra: %{}},
       model: state.model,
       stop_reason: reason,
       usage: usage
     }}
  end

  defp put_block(state, index, block), do: %{state | blocks: Map.put(state.blocks, index, block)}

  # A delta for a block that never opened is dropped rather than raised on:
  # the fold is fed by performers, and a malformed stream must not crash the
  # caller's connection process.
  defp append(state, index, key, text) do
    case state.blocks do
      %{^index => block} -> put_block(state, index, Map.update!(block, key, &(&1 <> text)))
      _ -> state
    end
  end

  defp finish(%{type: :tool_call, input_json: json} = block),
    do: Map.put(block, :input, decode_input(json))

  defp finish(block), do: block

  defp decode_input(""), do: %{}

  defp decode_input(json) do
    case Jason.decode(json) do
      {:ok, %{} = input} -> input
      _ -> nil
    end
  end
end

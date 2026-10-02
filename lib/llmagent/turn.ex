defmodule LLMAgent.Turn do
  @moduledoc """
  The canonical generate request: one turn of a conversation, independent of
  any vendor wire protocol.

  Codecs translate at the edges — `LLMAgent.Codec.Anthropic` for what clients
  send, `LLMAgent.Codec.OpenAI` for what performers expect — and everything
  between them speaks this struct and the canonical events in `t:event/0`.

  Every level carries an `extra` map for protocol-specific fields the
  canonical model has no word for. `extra` is re-emitted when a turn leaves
  in the protocol it arrived in and dropped when it crosses protocols.

  See `docs/superpowers/specs/2026-10-02-private-llm-hub-design.md`.
  """

  @enforce_keys []
  defstruct model: nil,
            system: [],
            messages: [],
            tools: [],
            tool_choice: nil,
            params: %{},
            stream: false,
            extra: %{}

  @typedoc """
  A content block. `:type` is one of `:text`, `:image`, `:tool_call`,
  `:tool_result`, `:reasoning`; the other keys depend on it. Always has `:extra`.
  """
  @type block :: map()

  @type role :: :user | :assistant | :system

  @type message :: %{role: role(), content: [block()], extra: map()}

  @type tool :: %{
          name: String.t(),
          description: String.t() | nil,
          input_schema: map(),
          extra: map()
        }

  @type tool_choice :: :auto | :none | :required | {:tool, String.t()} | nil

  @type t :: %__MODULE__{
          model: String.t() | nil,
          system: [block()],
          messages: [message()],
          tools: [tool()],
          tool_choice: tool_choice(),
          params: map(),
          stream: boolean(),
          extra: map()
        }

  @type stop_reason :: :end_turn | :tool_use | :max_tokens | :stop_sequence

  @type usage :: %{input_tokens: integer() | nil, output_tokens: integer() | nil}

  @typedoc "What kind of block a `:block_start` opens."
  @type block_kind :: :text | :reasoning | {:tool_call, id :: String.t(), name :: String.t()}

  @typedoc "Any reason a stream failed. Producer-defined."
  @type error_reason :: term()

  @typedoc """
  A canonical stream event. Blocks are indexed from 0 in the order they open,
  and a block is always stopped before the next one starts.
  """
  @type event ::
          {:start, %{model: String.t() | nil}}
          | {:block_start, non_neg_integer(), block_kind()}
          | {:text_delta, non_neg_integer(), binary()}
          | {:reasoning_delta, non_neg_integer(), binary()}
          | {:tool_args_delta, non_neg_integer(), binary()}
          | {:block_stop, non_neg_integer()}
          | {:stop, stop_reason(), usage()}
          | {:error, error_reason()}
end

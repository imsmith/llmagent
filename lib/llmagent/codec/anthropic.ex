defmodule LLMAgent.Codec.Anthropic do
  @moduledoc """
  Translates between the Anthropic Messages wire format and the canonical
  `LLMAgent.Turn`, client side: a client's request comes in as a turn, and
  canonical events (`t:LLMAgent.Turn.event/0`) go back out as the SSE stream
  that client expects.

  Pure functions, apart from generating a message id when none is supplied.

  ## What is kept, dropped, and refused

  A real client sends fields this model has no word for at every level — the
  request, each message, each tool, each block. They are never a reason to
  refuse: each is kept in the `extra` of the thing it was found on.

  Two things are refused, because dropping them would change what the turn
  means: a content block of an unknown type, and a tool entry that is a
  vendor server-side tool (it has a `type` other than `custom`), which a
  performer cannot run.

  Two things that look like those are carried instead, because refusing them
  would end a session for good — once such a block is in a conversation's
  history, every later request would be refused too:

    * `redacted_thinking` becomes a `:reasoning` block with empty text and
      the original block under `extra["redacted_thinking"]`.
    * A block of unknown type *inside a tool result* becomes a text marker,
      `[<type> block omitted]`, with the original block under
      `extra["omitted"]`. The tool already ran; only its report is degraded.

  Wire strings are mapped to atoms by explicit clauses only.

  ## Stream shape

  Each block is stopped before the next one starts, and no `signature_delta`
  is emitted. (llama-server's own Anthropic stream defers every
  `content_block_stop` to the end; that is its habit, not the protocol.)
  """

  alias LLMAgent.Turn
  alias LLMAgent.Turn.Fold

  @enforce_keys [:model, :id]
  defstruct model: nil, id: nil, failed: false

  @typedoc "Stream encoder state."
  @opaque encoder :: %__MODULE__{}

  @typedoc "A decoded JSON object from, or bound for, the wire."
  @type wire :: map()

  @type decode_error :: {:unsupported, String.t()} | {:invalid, String.t()}

  # --- request decoding ---

  @doc """
  Decode a Messages request body into a turn.

  Returns `{:error, {:unsupported, what}}` for a feature that cannot be
  carried, and `{:error, {:invalid, what}}` for a malformed request.
  """
  @spec decode_request(wire()) :: {:ok, Turn.t()} | {:error, decode_error()}
  def decode_request(%{"messages" => messages} = wire) when is_list(messages) do
    with {:ok, system} <- decode_content(wire["system"]),
         {:ok, messages} <- map_ok(messages, &decode_message/1),
         {:ok, tools} <- map_ok(wire["tools"] || [], &decode_tool/1),
         {:ok, tool_choice} <- decode_tool_choice(wire["tool_choice"]) do
      {:ok,
       %Turn{
         model: wire["model"],
         system: system,
         messages: messages,
         tools: tools,
         tool_choice: tool_choice,
         params: decode_params(wire),
         stream: wire["stream"] == true,
         extra: Map.drop(wire, ~w(model system messages tools tool_choice stream max_tokens temperature top_p stop_sequences))
       }}
    end
  end

  def decode_request(_wire), do: {:error, {:invalid, "messages must be a list"}}

  defp decode_params(wire) do
    for {wire_key, key} <- [
          {"max_tokens", :max_tokens},
          {"temperature", :temperature},
          {"top_p", :top_p},
          {"stop_sequences", :stop}
        ],
        Map.has_key?(wire, wire_key),
        into: %{},
        do: {key, Map.fetch!(wire, wire_key)}
  end

  defp decode_message(%{"role" => role} = wire) do
    with {:ok, role} <- decode_role(role),
         {:ok, content} <- decode_content(wire["content"]) do
      {:ok, %{role: role, content: content, extra: Map.drop(wire, ~w(role content))}}
    end
  end

  defp decode_message(_wire), do: {:error, {:invalid, "message without a role"}}

  defp decode_role("user"), do: {:ok, :user}
  defp decode_role("assistant"), do: {:ok, :assistant}
  defp decode_role("system"), do: {:ok, :system}
  defp decode_role(other), do: {:error, {:unsupported, "role: #{inspect(other)}"}}

  # Content is a bare string, a list of blocks, or absent.
  defp decode_content(nil), do: {:ok, []}
  defp decode_content(text) when is_binary(text), do: {:ok, [%{type: :text, text: text, extra: %{}}]}
  defp decode_content(blocks) when is_list(blocks), do: map_ok(blocks, &decode_block/1)
  defp decode_content(_other), do: {:error, {:invalid, "content must be a string or a list"}}

  defp decode_block(%{"type" => "text", "text" => text} = wire) when is_binary(text),
    do: {:ok, %{type: :text, text: text, extra: Map.drop(wire, ~w(type text))}}

  defp decode_block(%{"type" => "redacted_thinking"} = wire),
    do: {:ok, %{type: :reasoning, text: "", extra: %{"redacted_thinking" => wire}}}

  defp decode_block(%{"type" => "thinking"} = wire),
    do: {:ok, %{type: :reasoning, text: wire["thinking"] || "", extra: Map.drop(wire, ~w(type thinking))}}

  defp decode_block(%{"type" => "image", "source" => %{"type" => "base64"} = source} = wire) do
    {:ok,
     %{
       type: :image,
       media_type: source["media_type"],
       data: source["data"],
       extra: Map.drop(wire, ~w(type source))
     }}
  end

  defp decode_block(%{"type" => "image", "source" => %{} = source}),
    do: {:error, {:unsupported, "image source: #{inspect(source["type"])}"}}

  defp decode_block(%{"type" => "tool_use", "id" => id, "name" => name} = wire)
       when is_binary(id) and is_binary(name) do
    input = wire["input"] || %{}

    {:ok,
     %{
       type: :tool_call,
       id: id,
       name: name,
       input: input,
       input_json: Jason.encode!(input),
       extra: Map.drop(wire, ~w(type id name input))
     }}
  end

  defp decode_block(%{"type" => "tool_result", "tool_use_id" => id} = wire) when is_binary(id) do
    with {:ok, content} <- decode_result_content(wire["content"]) do
      {:ok,
       %{
         type: :tool_result,
         tool_call_id: id,
         content: content,
         is_error: wire["is_error"] == true,
         extra: Map.drop(wire, ~w(type tool_use_id content is_error))
       }}
    end
  end

  defp decode_block(%{"type" => type}) when type in ~w(text image tool_use tool_result),
    do: {:error, {:invalid, "malformed #{type} block"}}

  defp decode_block(%{"type" => type}), do: {:error, {:unsupported, "content block type: #{inspect(type)}"}}
  defp decode_block(_wire), do: {:error, {:invalid, "content block without a type"}}

  # A tool result's content, where a block of unknown type is degraded to a
  # text marker rather than refused.
  defp decode_result_content(blocks) when is_list(blocks) do
    map_ok(blocks, fn block ->
      case decode_block(block) do
        {:error, {:unsupported, _}} when is_map(block) -> {:ok, omitted(block)}
        other -> other
      end
    end)
  end

  defp decode_result_content(other), do: decode_content(other)

  defp omitted(%{"type" => type} = wire) when is_binary(type),
    do: %{type: :text, text: "[#{type} block omitted]", extra: %{"omitted" => wire}}

  defp decode_tool(%{"type" => type}) when type != "custom",
    do: {:error, {:unsupported, "server tool: #{inspect(type)}"}}

  defp decode_tool(%{"name" => name} = wire) do
    {:ok,
     %{
       name: name,
       description: wire["description"],
       input_schema: wire["input_schema"] || %{},
       extra: Map.drop(wire, ~w(name description input_schema))
     }}
  end

  defp decode_tool(_wire), do: {:error, {:invalid, "tool without a name"}}

  defp decode_tool_choice(nil), do: {:ok, nil}
  defp decode_tool_choice(%{"type" => "auto"}), do: {:ok, :auto}
  defp decode_tool_choice(%{"type" => "any"}), do: {:ok, :required}
  defp decode_tool_choice(%{"type" => "none"}), do: {:ok, :none}
  defp decode_tool_choice(%{"type" => "tool", "name" => name}), do: {:ok, {:tool, name}}
  defp decode_tool_choice(other), do: {:error, {:unsupported, "tool_choice: #{inspect(other)}"}}

  defp map_ok(list, fun) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # --- stream encoding ---

  @doc """
  A fresh stream encoder. Options:

    * `:model` — the model string to report to the client; pass the one the
      client asked for, not the performer's
    * `:id` — the message id; generated when absent
  """
  @spec stream_encoder(keyword()) :: encoder()
  def stream_encoder(opts \\ []) do
    %__MODULE__{model: Keyword.get(opts, :model), id: Keyword.get(opts, :id) || message_id()}
  end

  @doc "Encode one canonical event as zero or more SSE frames."
  @spec encode_stream(encoder(), Turn.event()) :: {iodata(), encoder()}
  def encode_stream(%__MODULE__{failed: true} = state, _event), do: {[], state}

  def encode_stream(%__MODULE__{} = state, {:start, _meta}) do
    message = %{
      "id" => state.id,
      "type" => "message",
      "role" => "assistant",
      "content" => [],
      "model" => state.model,
      "stop_reason" => nil,
      "stop_sequence" => nil,
      "usage" => wire_usage(%{})
    }

    {frame("message_start", %{"message" => message}), state}
  end

  def encode_stream(state, {:block_start, index, kind}),
    do: {frame("content_block_start", %{"index" => index, "content_block" => empty_block(kind)}), state}

  def encode_stream(state, {:text_delta, index, text}),
    do: {delta(index, %{"type" => "text_delta", "text" => text}), state}

  def encode_stream(state, {:reasoning_delta, index, text}),
    do: {delta(index, %{"type" => "thinking_delta", "thinking" => text}), state}

  def encode_stream(state, {:tool_args_delta, index, json}),
    do: {delta(index, %{"type" => "input_json_delta", "partial_json" => json}), state}

  def encode_stream(state, {:block_stop, index}),
    do: {frame("content_block_stop", %{"index" => index}), state}

  def encode_stream(state, {:stop, reason, usage}) do
    message_delta = %{
      "delta" => %{"stop_reason" => wire_stop_reason(reason), "stop_sequence" => nil},
      "usage" => wire_usage(usage)
    }

    {[frame("message_delta", message_delta), frame("message_stop", %{})], state}
  end

  def encode_stream(state, {:error, reason}) do
    error = %{"type" => "api_error", "message" => describe(reason)}
    {frame("error", %{"error" => error}), %{state | failed: true}}
  end

  defp delta(index, delta), do: frame("content_block_delta", %{"index" => index, "delta" => delta})

  defp frame(type, body),
    do: ["event: ", type, "\ndata: ", Jason.encode_to_iodata!(Map.put(body, "type", type)), "\n\n"]

  defp empty_block(:text), do: %{"type" => "text", "text" => ""}
  defp empty_block(:reasoning), do: %{"type" => "thinking", "thinking" => ""}

  defp empty_block({:tool_call, id, name}),
    do: %{"type" => "tool_use", "id" => id, "name" => name, "input" => %{}}

  defp wire_stop_reason(:end_turn), do: "end_turn"
  defp wire_stop_reason(:tool_use), do: "tool_use"
  defp wire_stop_reason(:max_tokens), do: "max_tokens"
  defp wire_stop_reason(:stop_sequence), do: "stop_sequence"

  defp wire_usage(usage),
    do: %{"input_tokens" => usage[:input_tokens] || 0, "output_tokens" => usage[:output_tokens] || 0}

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp message_id, do: "msg_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

  # --- non-streaming response and errors ---

  @doc """
  Encode a folded turn (`t:LLMAgent.Turn.Fold.result/0`) as a non-streaming
  Messages response body. Takes the same options as `stream_encoder/1`.
  """
  @spec encode_response(Fold.result(), keyword()) :: wire()
  def encode_response(%{message: message, stop_reason: reason, usage: usage}, opts \\ []) do
    %{
      "id" => Keyword.get(opts, :id) || message_id(),
      "type" => "message",
      "role" => "assistant",
      "model" => Keyword.get(opts, :model),
      "content" => Enum.map(message.content, &encode_block/1),
      "stop_reason" => wire_stop_reason(reason),
      "stop_sequence" => nil,
      "usage" => wire_usage(usage)
    }
  end

  defp encode_block(%{type: :text, text: text}), do: %{"type" => "text", "text" => text}

  defp encode_block(%{type: :reasoning, text: text}),
    do: %{"type" => "thinking", "thinking" => text, "signature" => ""}

  defp encode_block(%{type: :tool_call} = block),
    do: %{"type" => "tool_use", "id" => block.id, "name" => block.name, "input" => block.input || %{}}

  @doc "An error body in Anthropic's envelope, with the error type chosen from the HTTP status."
  @spec encode_error(pos_integer(), String.t()) :: wire()
  def encode_error(status, message) when is_integer(status) and is_binary(message),
    do: %{"type" => "error", "error" => %{"type" => error_type(status), "message" => message}}

  defp error_type(400), do: "invalid_request_error"
  defp error_type(401), do: "authentication_error"
  defp error_type(403), do: "permission_error"
  defp error_type(404), do: "not_found_error"
  defp error_type(429), do: "rate_limit_error"
  defp error_type(_other), do: "api_error"
end

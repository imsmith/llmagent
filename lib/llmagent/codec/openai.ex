defmodule LLMAgent.Codec.OpenAI do
  @moduledoc """
  Translates between the canonical `LLMAgent.Turn` and the OpenAI Chat
  Completions wire format, performer side: a turn goes out as a request, and
  the performer's reply comes back as canonical events
  (`t:LLMAgent.Turn.event/0`).

  Pure functions. No processes, no I/O.

  ## Encoding choices

  Chat templates differ between models, and some refuse a `system` message
  anywhere but first (`test/fixtures/wire/openai_error_500_template.json` is
  one doing so). The request is therefore encoded portably: the turn's system
  blocks become one leading `system` message, a `:system` message later in
  the conversation becomes `user` text, and adjacent messages of the same
  role are merged.

  A performer expects every `tool` message directly after the assistant
  message that made the calls, so anything that would fall between them —
  a system reminder turned into user text — is moved to after the results.
  An image inside a tool result cannot ride in a `tool` message; it follows
  in a user message.

  This is a protocol crossing, so every `extra` map is dropped and
  `:reasoning` blocks are not sent back to the performer.

  ## Decoding choices

  OpenAI Chat has no block boundaries. The decoder opens a block when the
  kind of delta changes or a new tool-call index appears, and always stops
  the open block first. Canonical block indices count blocks in opening
  order; they are not the wire's tool-call index.

  The `:stop` event is held until `data: [DONE]`, because usage arrives in a
  chunk after the one carrying the finish reason.

  The decoder is fed by performers and never raises on what they send. A
  chunk of the wrong shape ends the stream with `{:error, {:bad_frame, _}}`.
  Arguments arriving for a tool call whose block has already been stopped
  end it with `{:error, {:out_of_order_tool_call, wire_index}}`: a delta is
  never emitted for a closed block.
  """

  alias LLMAgent.Codec.SSE
  alias LLMAgent.Turn

  @enforce_keys [:sse]
  defstruct sse: nil,
            started: false,
            open: nil,
            next_index: 0,
            tools: %{},
            finish: nil,
            usage: %{input_tokens: nil, output_tokens: nil},
            done: false

  @typedoc "Stream decoder state."
  @opaque decoder :: %__MODULE__{}

  @typedoc "A decoded JSON object from, or bound for, the wire."
  @type wire :: map()

  # --- request encoding ---

  @doc """
  Encode a turn as a Chat Completions request body for `model`, the
  performer's own model id (the client's `turn.model` is not sent).
  """
  @spec encode_request(Turn.t(), String.t()) :: wire()
  def encode_request(%Turn{} = turn, model) when is_binary(model) do
    %{"model" => model, "messages" => encode_messages(turn), "stream" => turn.stream}
    |> put_if(turn.stream, "stream_options", %{"include_usage" => true})
    |> put_if(turn.tools != [], "tools", Enum.map(turn.tools, &encode_tool/1))
    |> put_if(turn.tool_choice != nil, "tool_choice", encode_tool_choice(turn.tool_choice))
    |> Map.merge(encode_params(turn.params))
  end

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map

  defp encode_params(params) do
    for {key, wire_key} <- [max_tokens: "max_tokens", temperature: "temperature", top_p: "top_p", stop: "stop"],
        Map.has_key?(params, key),
        into: %{},
        do: {wire_key, Map.fetch!(params, key)}
  end

  defp encode_tool(tool) do
    function =
      %{"name" => tool.name, "parameters" => tool.input_schema}
      |> put_if(is_binary(tool.description), "description", tool.description)

    %{"type" => "function", "function" => function}
  end

  defp encode_tool_choice(nil), do: nil
  defp encode_tool_choice(:auto), do: "auto"
  defp encode_tool_choice(:none), do: "none"
  defp encode_tool_choice(:required), do: "required"
  defp encode_tool_choice({:tool, name}), do: %{"type" => "function", "function" => %{"name" => name}}

  defp encode_messages(%Turn{system: system, messages: messages}) do
    leading =
      case block_text(system) do
        "" -> []
        text -> [%{"role" => "system", "content" => text}]
      end

    leading ++
      (messages |> Enum.flat_map(&encode_message/1) |> keep_tool_results_adjacent() |> merge_adjacent())
  end

  defp encode_message(%{role: :system, content: content}) do
    case block_text(content) do
      "" -> []
      text -> [%{"role" => "user", "content" => text}]
    end
  end

  defp encode_message(%{role: :assistant, content: content}) do
    text = block_text(content)
    calls = for %{type: :tool_call} = block <- content, do: encode_tool_call(block)

    if text == "" and calls == [] do
      []
    else
      [
        %{"role" => "assistant", "content" => if(text == "", do: nil, else: text)}
        |> put_if(calls != [], "tool_calls", calls)
      ]
    end
  end

  # Tool results come first: a performer expects every tool message directly
  # after the assistant message that made the calls.
  defp encode_message(%{role: :user, content: content}) do
    results = for %{type: :tool_result} = block <- content, do: encode_tool_result(block)

    # A tool message carries text only, so images a tool returned travel in
    # the user message that follows.
    result_images =
      for %{type: :tool_result, content: inner} <- content, %{type: :image} = image <- inner, do: image

    parts = Enum.flat_map(result_images ++ content, &encode_part/1)

    user =
      cond do
        parts == [] -> []
        Enum.all?(parts, &(&1["type"] == "text")) -> [%{"role" => "user", "content" => join_text(parts)}]
        true -> [%{"role" => "user", "content" => parts}]
      end

    results ++ user
  end

  defp encode_tool_result(block) do
    content =
      case {block_text(block.content), Enum.any?(block.content, &(&1.type == :image))} do
        {"", true} -> "[image attached below]"
        {text, _} -> text
      end

    %{"role" => "tool", "tool_call_id" => block.tool_call_id, "content" => content}
  end

  defp encode_part(%{type: :text, text: text}), do: [%{"type" => "text", "text" => text}]

  defp encode_part(%{type: :image, media_type: media_type, data: data}),
    do: [%{"type" => "image_url", "image_url" => %{"url" => "data:#{media_type};base64,#{data}"}}]

  defp encode_part(_other), do: []

  defp encode_tool_call(block) do
    %{
      "id" => block.id,
      "type" => "function",
      "function" => %{"name" => block.name, "arguments" => arguments(block)}
    }
  end

  defp arguments(%{input_json: json}) when is_binary(json) and json != "", do: json
  defp arguments(%{input: %{} = input}), do: Jason.encode!(input)
  defp arguments(_block), do: "{}"

  defp block_text(blocks) do
    blocks
    |> Enum.flat_map(fn
      %{type: :text, text: text} -> [text]
      _other -> []
    end)
    |> Enum.join("\n\n")
  end

  defp join_text(parts), do: Enum.map_join(parts, "\n\n", & &1["text"])

  # While an assistant message's tool calls are still owed results, a user
  # message is held back and released after the last of them.
  defp keep_tool_results_adjacent(messages) do
    {acc, _owed, held} =
      Enum.reduce(messages, {[], 0, []}, fn
        %{"role" => "assistant", "tool_calls" => calls} = message, {acc, _owed, held} ->
          {[message | held ++ acc], length(calls), []}

        %{"role" => "tool"} = message, {acc, owed, held} when owed > 1 ->
          {[message | acc], owed - 1, held}

        %{"role" => "tool"} = message, {acc, _owed, held} ->
          {held ++ [message | acc], 0, []}

        %{"role" => "user"} = message, {acc, owed, held} when owed > 0 ->
          {acc, owed, [message | held]}

        message, {acc, _owed, held} ->
          {[message | held ++ acc], 0, []}
      end)

    Enum.reverse(held ++ acc)
  end

  defp merge_adjacent(messages) do
    messages
    |> Enum.reduce([], fn
      %{"role" => role} = message, [%{"role" => role} = previous | rest] when role in ["user", "assistant"] ->
        [merge(previous, message) | rest]

      message, acc ->
        [message | acc]
    end)
    |> Enum.reverse()
  end

  defp merge(%{"role" => "user"} = a, b),
    do: %{a | "content" => merge_content(a["content"], b["content"])}

  defp merge(%{"role" => "assistant"} = a, b) do
    calls = Map.get(a, "tool_calls", []) ++ Map.get(b, "tool_calls", [])

    %{"role" => "assistant", "content" => merge_content(a["content"], b["content"])}
    |> put_if(calls != [], "tool_calls", calls)
  end

  defp merge_content(nil, b), do: b
  defp merge_content(a, nil), do: a
  defp merge_content(a, b) when is_binary(a) and is_binary(b), do: a <> "\n\n" <> b
  defp merge_content(a, b), do: to_parts(a) ++ to_parts(b)

  defp to_parts(text) when is_binary(text), do: [%{"type" => "text", "text" => text}]
  defp to_parts(parts) when is_list(parts), do: parts

  # --- stream decoding ---

  @doc "A fresh stream decoder state."
  @spec stream_decoder() :: decoder()
  def stream_decoder, do: %__MODULE__{sse: SSE.new()}

  @doc "Feed the next chunk of response bytes; returns the events it produced."
  @spec decode_stream(decoder(), binary()) :: {[Turn.event()], decoder()}
  def decode_stream(%__MODULE__{} = state, bytes) when is_binary(bytes) do
    {frames, sse} = SSE.feed(state.sse, bytes)

    {events, state} =
      Enum.reduce(frames, {[], %{state | sse: sse}}, fn frame, {acc, state} ->
        {events, state} = decode_frame(frame, state)
        {[events | acc], state}
      end)

    {events |> Enum.reverse() |> List.flatten(), state}
  end

  @doc """
  Call when the response body has ended. Returns `[]` if the stream already
  stopped. A stream that reported a finish reason but never sent `[DONE]` is
  stopped normally; one that ended with no finish reason has its open block
  closed and ends with `{:error, :incomplete_stream}`.
  """
  @spec finish_stream(decoder()) :: [Turn.event()]
  def finish_stream(%__MODULE__{done: true}), do: []

  def finish_stream(%__MODULE__{} = state) do
    {events, _state} = terminate(state)
    events
  end

  # Anything after the stream has ended is ignored.
  defp decode_frame(_frame, %__MODULE__{done: true} = state), do: {[], state}
  defp decode_frame(%{data: "[DONE]"}, state), do: terminate(state)

  defp decode_frame(%{data: data}, state) do
    case Jason.decode(data) do
      {:ok, %{"error" => error}} when not is_nil(error) -> fail(state, {:upstream, error})
      {:ok, %{} = chunk} -> if well_formed?(chunk), do: decode_chunk(chunk, state), else: fail(state, {:bad_frame, data})
      _ -> fail(state, {:bad_frame, data})
    end
  end

  # Everything decode_chunk/2 reads, checked once so that nothing below has
  # to defend against a performer sending the wrong type.
  defp well_formed?(chunk) do
    choices = chunk["choices"] || []

    optional?(chunk["usage"], &is_map/1) and optional?(chunk["model"], &is_binary/1) and
      is_list(choices) and Enum.all?(choices, &well_formed_choice?/1)
  end

  defp well_formed_choice?(%{} = choice) do
    delta = choice["delta"] || %{}
    calls = (is_map(delta) && delta["tool_calls"]) || []

    optional?(choice["finish_reason"], &is_binary/1) and is_map(delta) and
      optional?(delta["content"], &is_binary/1) and optional?(delta["reasoning_content"], &is_binary/1) and
      is_list(calls) and Enum.all?(calls, &well_formed_call?/1)
  end

  defp well_formed_choice?(_other), do: false

  defp well_formed_call?(%{} = call) do
    function = call["function"] || %{}

    optional?(call["index"], &is_integer/1) and optional?(call["id"], &is_binary/1) and is_map(function) and
      optional?(function["name"], &is_binary/1) and optional?(function["arguments"], &is_binary/1)
  end

  defp well_formed_call?(_other), do: false

  defp optional?(nil, _check), do: true
  defp optional?(value, check), do: check.(value)

  defp terminate(state) do
    {closing, state} = close_open(state)

    last =
      case state.finish do
        nil -> {:error, :incomplete_stream}
        reason -> {:stop, reason, state.usage}
      end

    {closing ++ [last], %{state | done: true}}
  end

  defp fail(state, reason) do
    {closing, state} = close_open(state)
    {closing ++ [{:error, reason}], %{state | done: true}}
  end

  defp decode_chunk(chunk, state) do
    {start, state} = start(chunk, state)
    state = %{state | usage: usage(chunk["usage"], state.usage)}
    choice = List.first(chunk["choices"] || []) || %{}
    {deltas, state} = decode_delta(choice["delta"] || %{}, state)
    {finish, state} = decode_finish(choice["finish_reason"], state)

    {start ++ deltas ++ finish, state}
  end

  defp start(_chunk, %__MODULE__{started: true} = state), do: {[], state}
  defp start(chunk, state), do: {[{:start, %{model: chunk["model"]}}], %{state | started: true}}

  defp usage(%{} = usage, _current),
    do: %{input_tokens: usage["prompt_tokens"], output_tokens: usage["completion_tokens"]}

  defp usage(_absent, current), do: current

  defp decode_delta(delta, state) do
    {reasoning, state} = text_delta(delta["reasoning_content"], :reasoning, :reasoning_delta, state)
    {text, state} = text_delta(delta["content"], :text, :text_delta, state)

    {calls, state} =
      Enum.reduce(delta["tool_calls"] || [], {[], state}, fn
        _call, {acc, %__MODULE__{done: true} = state} ->
          {acc, state}

        call, {acc, state} ->
          {events, state} = tool_delta(call, state)
          {acc ++ events, state}
      end)

    {reasoning ++ text ++ calls, state}
  end

  defp text_delta(text, kind, tag, state) when is_binary(text) and text != "" do
    {opening, index, state} = ensure_open(state, kind)
    {opening ++ [{tag, index, text}], state}
  end

  defp text_delta(_absent, _kind, _tag, state), do: {[], state}

  defp tool_delta(call, state) do
    wire_index = call["index"] || 0
    function = call["function"] || %{}

    case state.tools do
      %{^wire_index => index} when state.open != {index, {:tool, wire_index}} ->
        fail(state, {:out_of_order_tool_call, wire_index})

      _ ->
        tool_args(call, wire_index, function, state)
    end
  end

  defp tool_args(call, wire_index, function, state) do
    {opening, index, state} =
      case state.tools do
        %{^wire_index => index} ->
          {[], index, state}

        _ ->
          id = call["id"] || "call_#{wire_index}"
          {closing, state} = close_open(state)
          index = state.next_index

          state = %{
            state
            | open: {index, {:tool, wire_index}},
              next_index: index + 1,
              tools: Map.put(state.tools, wire_index, index)
          }

          {closing ++ [{:block_start, index, {:tool_call, id, function["name"] || ""}}], index, state}
      end

    case function["arguments"] do
      args when is_binary(args) and args != "" -> {opening ++ [{:tool_args_delta, index, args}], state}
      _ -> {opening, state}
    end
  end

  defp ensure_open(%__MODULE__{open: {index, kind}} = state, kind), do: {[], index, state}

  defp ensure_open(state, kind) do
    {closing, state} = close_open(state)
    index = state.next_index
    {closing ++ [{:block_start, index, kind}], index, %{state | open: {index, kind}, next_index: index + 1}}
  end

  defp close_open(%__MODULE__{open: nil} = state), do: {[], state}
  defp close_open(%__MODULE__{open: {index, _kind}} = state), do: {[{:block_stop, index}], %{state | open: nil}}

  defp decode_finish(nil, state), do: {[], state}
  defp decode_finish(_reason, %__MODULE__{done: true} = state), do: {[], state}

  defp decode_finish(reason, state) do
    {closing, state} = close_open(state)
    {closing, %{state | finish: stop_reason(reason)}}
  end

  defp stop_reason("tool_calls"), do: :tool_use
  defp stop_reason("length"), do: :max_tokens
  defp stop_reason(_stop_or_unknown), do: :end_turn

  # --- non-streaming response decoding ---

  @doc """
  Decode a non-streaming Chat Completions response body into the same event
  sequence a stream of that reply would have produced.
  """
  @spec decode_response(wire()) :: [Turn.event()]
  def decode_response(%{"error" => error}), do: [{:error, {:upstream, error}}]

  def decode_response(%{} = body) do
    choice = List.first(body["choices"] || []) || %{}
    message = choice["message"] || %{}

    blocks =
      whole_text(message["reasoning_content"], :reasoning, :reasoning_delta) ++
        whole_text(message["content"], :text, :text_delta) ++
        Enum.map(message["tool_calls"] || [], &whole_tool_call/1)

    indexed =
      blocks
      |> Enum.with_index()
      |> Enum.flat_map(fn {{kind, deltas}, index} ->
        [{:block_start, index, kind}] ++
          Enum.map(deltas, fn {tag, data} -> {tag, index, data} end) ++ [{:block_stop, index}]
      end)

    usage = usage(body["usage"], %{input_tokens: nil, output_tokens: nil})

    [{:start, %{model: body["model"]}}] ++ indexed ++ [{:stop, stop_reason(choice["finish_reason"]), usage}]
  end

  defp whole_text(text, kind, tag) when is_binary(text) and text != "", do: [{kind, [{tag, text}]}]
  defp whole_text(_absent, _kind, _tag), do: []

  defp whole_tool_call(call) do
    function = call["function"] || %{}

    deltas =
      case function["arguments"] do
        args when is_binary(args) and args != "" -> [{:tool_args_delta, args}]
        _ -> []
      end

    {{:tool_call, call["id"] || "call_0", function["name"] || ""}, deltas}
  end
end

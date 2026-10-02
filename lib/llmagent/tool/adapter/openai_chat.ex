defmodule LLMAgent.Tool.Adapter.OpenAIChat do
  @moduledoc """
  Binding adapter that bridges the `:generate` kind to an OpenAI-compatible
  chat-completions HTTP endpoint by delegating to `LLMAgent.LLMClient.OpenAI`.

  Binding payload shape:

      %{api_host: "http://10.10.1.226:8080", model: "gemma-..."}

  The `:openai_chat` binding kind is registered at boot in
  `LLMAgent.Tool.Bindings.init_registry/0`.

  Supported actions: `"chat"`. Other actions return `{:error, :unknown_action}`.

  ## Two argument shapes

  `%{messages: [...]}` is the original shape: one blocking call through
  `LLMAgent.LLMClient.OpenAI` that returns the reply's text.

  `%{turn: %LLMAgent.Turn{}}` carries a whole canonical turn — system, tools,
  tool calls and results — and always streams from the performer:

    * `opts[:into]` — optional function of one canonical event
      (`t:LLMAgent.Turn.event/0`) returning `:cont` or `:halt`. `:halt`
      cancels the upstream request.
    * `opts[:timeout]` — receive timeout in milliseconds, default 120000.

  It returns `{:ok, message, provenance}` with the folded assistant message
  and `%{model:, stop_reason:, usage:, latency_ms:}`, or:

    * `{:error, {:http_error, status, body}}` — the performer answered with
      an error instead of a stream; `body` is decoded when it is JSON
    * `{:error, :halted}` — `into` asked to stop
    * `{:error, :incomplete_stream}` — the reply ended without finishing;
      `into` is passed the `:error` event first
    * `{:error, reason}` — transport failure, or an error the performer
      reported inside the stream. If the reply had already started, `into`
      is passed `{:error, reason}` first, so a stream in flight is never
      left without an ending.
  """

  @behaviour LLMAgent.Tool.Adapter

  alias LLMAgent.Codec
  alias LLMAgent.LLMClient.OpenAI
  alias LLMAgent.Turn
  alias LLMAgent.Turn.Fold

  # An error body is kept for the caller, but a performer cannot make us
  # buffer without bound.
  @max_error_body 65_536

  @impl true
  def generate(%{api_host: host, model: model}, "chat", %{turn: %Turn{} = turn}, opts) do
    into = Keyword.get(opts, :into, fn _event -> :cont end)
    started = System.monotonic_time(:millisecond)
    # Set once reply bytes arrive. The decoder state rides in the response,
    # which Req does not hand back when the transport fails mid-reply.
    replying = :atomics.new(1, [])

    request = [
      json: Codec.OpenAI.encode_request(%{turn | stream: true}, model),
      receive_timeout: Keyword.get(opts, :timeout, 120_000),
      retry: false,
      # The ad names the performer, and the caller chose it under a policy. A
      # redirect would carry the prompt somewhere that policy never saw.
      redirect: false,
      compressed: false,
      into: fn {:data, data}, {req, resp} ->
        if resp.status == 200, do: :atomics.put(replying, 1, 1)
        {verdict, state} = receive_data(resp.status, data, stream_state(resp), into)
        {verdict, {req, Req.Response.put_private(resp, :llmagent_turn, state)}}
      end
    ]

    case Req.post("#{host}/chat/completions", request) do
      {:ok, %Req.Response{status: 200} = resp} ->
        finish(stream_state(resp), into, model, started)

      {:ok, %Req.Response{status: status} = resp} ->
        {:error, {:http_error, status, error_body(stream_state(resp))}}

      {:error, reason} ->
        if :atomics.get(replying, 1) == 1, do: into.({:error, reason})
        {:error, reason}
    end
  end

  def generate(%{api_host: host, model: model} = _payload, "chat", args, opts) do
    messages = Map.fetch!(args, :messages)
    timeout = Keyword.get(opts, :timeout, 120_000)
    client = %{api_host: host, model: model, timeout: timeout}

    started = System.monotonic_time(:millisecond)

    case OpenAI.chat(messages, client) do
      {:ok, content} ->
        latency = System.monotonic_time(:millisecond) - started
        {:ok, content, %{model: model, latency_ms: latency}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def generate(_payload, _action, _args, _opts), do: {:error, :unknown_action}

  defp stream_state(resp) do
    Req.Response.get_private(resp, :llmagent_turn, %{
      decoder: Codec.OpenAI.stream_decoder(),
      fold: Fold.new(),
      halted: false,
      error_body: ""
    })
  end

  # Req delivers an error response's body through the same callback as a
  # stream, so the status decides what the bytes are.
  defp receive_data(200, data, state, into) do
    {events, decoder} = Codec.OpenAI.decode_stream(state.decoder, data)
    state = deliver(events, %{state | decoder: decoder}, into)
    {if(state.halted, do: :halt, else: :cont), state}
  end

  defp receive_data(_status, data, state, _into) do
    room = @max_error_body - byte_size(state.error_body)

    {:cont,
     %{state | error_body: state.error_body <> binary_part(data, 0, min(room, byte_size(data)))}}
  end

  defp deliver(events, state, into) do
    Enum.reduce_while(events, state, fn event, state ->
      state = %{state | fold: Fold.step(state.fold, event)}

      case into.(event) do
        :halt -> {:halt, %{state | halted: true}}
        _cont -> {:cont, state}
      end
    end)
  end

  defp finish(%{halted: true}, _into, _model, _started), do: {:error, :halted}

  defp finish(state, into, model, started) do
    state = deliver(Codec.OpenAI.finish_stream(state.decoder), state, into)

    case Fold.result(state.fold) do
      _any when state.halted ->
        {:error, :halted}

      {:ok, result} ->
        provenance = %{
          model: result.model || model,
          stop_reason: result.stop_reason,
          usage: result.usage,
          latency_ms: System.monotonic_time(:millisecond) - started
        }

        {:ok, result.message, provenance}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp error_body(%{error_body: raw}) do
    case Jason.decode(raw) do
      {:ok, decoded} -> decoded
      {:error, _} -> raw
    end
  end
end

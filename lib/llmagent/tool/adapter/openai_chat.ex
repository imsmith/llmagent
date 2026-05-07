defmodule LLMAgent.Tool.Adapter.OpenAIChat do
  @moduledoc """
  Binding adapter that bridges the `:generate` kind to an OpenAI-compatible
  chat-completions HTTP endpoint by delegating to `LLMAgent.LLMClient.OpenAI`.

  Binding payload shape:

      %{api_host: "http://10.10.1.226:8080", model: "gemma-..."}

  The `:openai_chat` binding kind is registered at boot in
  `LLMAgent.Tool.Bindings.init_registry/0`.

  Supported actions: `"chat"`. Other actions return `{:error, :unknown_action}`.
  """

  @behaviour LLMAgent.Tool.Adapter

  alias LLMAgent.LLMClient.OpenAI

  @impl true
  def generate(%{api_host: host, model: model} = _payload, "chat", args, opts) do
    messages = Map.fetch!(args, :messages)
    timeout  = Keyword.get(opts, :timeout, 120_000)
    client   = %{api_host: host, model: model, timeout: timeout}

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
end

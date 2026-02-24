defmodule LLMAgent.LLMClient.OpenAI do
  @moduledoc """
  OpenAI-compatible chat completions client.

  Sends requests to `{api_host}/chat/completions` and extracts the
  content string from the first choice.

  ## Examples

      iex> opts = %{api_host: "http://localhost:1", model: "gpt-4", timeout: 100}
      iex> {:error, _reason} = LLMAgent.LLMClient.OpenAI.chat([%{role: "user", content: "hi"}], opts)
  """

  @behaviour LLMAgent.LLMClient

  @doc """
  Send a chat completion request.

  Returns `{:ok, content}` on success or `{:error, reason}` on failure.

  ## Examples

      iex> opts = %{api_host: "http://localhost:1", model: "test", timeout: 100}
      iex> match?({:error, _}, LLMAgent.LLMClient.OpenAI.chat([], opts))
      true
  """
  @impl true
  def chat(messages, opts) do
    url = "#{opts.api_host}/chat/completions"
    timeout = Map.get(opts, :timeout, 120_000)

    case Req.post(url, json: %{model: opts.model, messages: messages}, receive_timeout: timeout) do
      {:ok, %Req.Response{body: %{"choices" => [%{"message" => %{"content" => content}} | _]}}} ->
        {:ok, content}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

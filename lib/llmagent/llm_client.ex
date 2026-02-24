defmodule LLMAgent.LLMClient do
  @moduledoc """
  Behaviour for LLM API clients.

  Implementations handle provider-specific HTTP calls and response parsing.
  The agent's Task.Supervisor provides async execution.

  ## Implementing a Client

      defmodule MyClient do
        @behaviour LLMAgent.LLMClient

        @impl true
        def chat(messages, opts) do
          # Call your LLM provider, return {:ok, content_string} or {:error, reason}
          {:ok, "response from " <> opts.model}
        end
      end
  """

  @type message :: %{role: String.t(), content: String.t()}
  @type opts :: %{api_host: String.t(), model: String.t(), timeout: non_neg_integer()}

  @callback chat(messages :: [message], opts :: opts) :: {:ok, String.t()} | {:error, term()}
end

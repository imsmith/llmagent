defmodule LLMAgent.Tool.Kinds.Action do
  @moduledoc """
  The `:action` kind. Side effects; not retryable without idempotency.

  See spec §3.2.
  """

  @doc "Execute an action with side effects. Accepts optional idempotency_key to prevent duplicate effects. Returns `{:ok, ack, meta}` on success or `{:error, reason}` on failure."
  @callback act(action :: String.t(), args :: map(), idempotency_key :: String.t() | nil) ::
              {:ok, ack :: term(), meta :: map()} | {:error, term()}
end

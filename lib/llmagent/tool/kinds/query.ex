defmodule LLMAgent.Tool.Kinds.Query do
  @moduledoc """
  The `:query` kind. Pure read; no side effects; idempotent.

  See spec §3.1.
  """

  @doc "Execute a read-only query. Pure, idempotent, no side effects. Returns `{:ok, value, meta}` on success or `{:error, reason}` on failure."
  @callback query(action :: String.t(), args :: map()) ::
              {:ok, value :: term(), meta :: map()} | {:error, term()}
end

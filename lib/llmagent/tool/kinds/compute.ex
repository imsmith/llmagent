defmodule LLMAgent.Tool.Kinds.Compute do
  @moduledoc """
  The `:compute` kind. Pure transformation; no I/O.

  See spec §3.4.
  """

  @doc "Execute a pure computation over args. No I/O, no side effects. Returns `{:ok, value}` on success or `{:error, reason}` on failure."
  @callback compute(action :: String.t(), args :: map()) ::
              {:ok, value :: term()} | {:error, term()}
end

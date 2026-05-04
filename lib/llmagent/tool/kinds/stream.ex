defmodule LLMAgent.Tool.Kinds.Stream do
  @moduledoc """
  The `:stream` kind. Subscribe/unsubscribe to event streams.

  See spec §3.3.
  """

  @doc "Subscribe to a stream. Returns `{:ok, sub_ref}` with a subscription reference or `{:error, reason}` on failure."
  @callback subscribe(action :: String.t(), args :: map(), subscriber :: pid()) ::
              {:ok, sub_ref :: reference()} | {:error, term()}

  @doc "Unsubscribe from a stream using the subscription reference. Returns `:ok`."
  @callback unsubscribe(sub_ref :: reference()) :: :ok
end

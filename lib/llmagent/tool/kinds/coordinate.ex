defmodule LLMAgent.Tool.Kinds.Coordinate do
  @moduledoc """
  The `:coordinate` kind. Multi-party interaction and consensus.

  See spec §3.5.
  """

  @doc "Participate in a coordinated interaction with a given role. Returns `{:ok, participation_ref}` or `{:error, reason}` on failure."
  @callback participate(role :: atom(), args :: map(), opts :: keyword()) ::
              {:ok, participation_ref :: reference()} | {:error, term()}

  @doc "Leave a coordination context using the participation reference. Returns `:ok`."
  @callback leave(participation_ref :: reference()) :: :ok
end

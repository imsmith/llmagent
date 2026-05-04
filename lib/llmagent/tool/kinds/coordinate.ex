defmodule LLMAgent.Tool.Kinds.Coordinate do
  @moduledoc """
  The `:coordinate` kind. Multi-party interaction and consensus.

  Use `:coordinate` when the tool mediates between multiple participants —
  leader election, distributed lock, consensus round, barrier synchronisation.
  A participant joins with a `role` atom, receives a participation reference,
  and later leaves via that reference. The tool owns the lifecycle of the
  coordination session; the agent is a participant, not the orchestrator.

  See `docs/superpowers/specs/2026-05-03-tool-discovery-design.md` §3.5.

  ## Minimal implementation

  Implement `@behaviour LLMAgent.Tool.Kinds.Coordinate` and define
  `participate/3` and `leave/1`:

  ```elixir
  @behaviour LLMAgent.Tool.Kinds.Coordinate

  @impl true
  def participate(:voter, _args, _opts) do
    ref = make_ref()
    # join session ...
    {:ok, ref}
  end

  @impl true
  def leave(ref) do
    # exit session ...
    :ok
  end
  ```
  """

  @doc "Participate in a coordinated interaction with a given role. Returns `{:ok, participation_ref}` or `{:error, reason}` on failure."
  @callback participate(role :: atom(), args :: map(), opts :: keyword()) ::
              {:ok, participation_ref :: reference()} | {:error, atom()}

  @doc "Leave a coordination context using the participation reference. Returns `:ok`."
  @callback leave(participation_ref :: reference()) :: :ok
end

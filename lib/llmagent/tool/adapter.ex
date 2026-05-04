defmodule LLMAgent.Tool.Adapter do
  @moduledoc """
  Behaviour for binding adapters. Each callback mirrors a kind's contract
  with the binding payload as the first argument.

  Adapters implement only the kinds their binding can carry. All callbacks
  are optional. See spec §4.1.
  """

  @doc "Execute a read-only query. Pure, idempotent, no side effects."
  @callback query(payload :: term(), action :: String.t(), args :: map(),
                  opts :: keyword()) ::
              {:ok, term(), map()} | {:error, term()}

  @doc "Execute an action with side effects. Accepts optional idempotency_key to prevent duplicate effects."
  @callback act(payload :: term(), action :: String.t(), args :: map(),
                idempotency_key :: String.t() | nil, opts :: keyword()) ::
              {:ok, term(), map()} | {:error, term()}

  @doc "Subscribe to stream updates."
  @callback subscribe(payload :: term(), action :: String.t(), args :: map(),
                      subscriber :: pid(), opts :: keyword()) ::
              {:ok, reference()} | {:error, term()}

  @doc "Unsubscribe from stream updates."
  @callback unsubscribe(payload :: term(), sub_ref :: reference(),
                        opts :: keyword()) :: :ok

  @doc "Compute a value asynchronously."
  @callback compute(payload :: term(), action :: String.t(), args :: map(),
                    opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @doc "Participate in a coordination session."
  @callback participate(payload :: term(), role :: atom(), args :: map(),
                        participant :: pid(), opts :: keyword()) ::
              {:ok, reference()} | {:error, term()}

  @doc "Leave a coordination session."
  @callback leave(payload :: term(), participation_ref :: reference(),
                  opts :: keyword()) :: :ok

  @doc "Spawn a child process."
  @callback spawn_child(payload :: term(), spec :: term(), context :: term(),
                        opts :: keyword()) ::
              {:ok, child_ref :: term()} | {:error, term()}

  @doc "Query the status of a child process."
  @callback child_status(payload :: term(), child_ref :: term(),
                         opts :: keyword()) :: term()

  @doc "Terminate a child process with the given reason."
  @callback terminate_child(payload :: term(), child_ref :: term(),
                            reason :: term(), opts :: keyword()) ::
              :ok | {:error, term()}

  @optional_callbacks query: 4, act: 5, subscribe: 5, unsubscribe: 3, compute: 4,
                      participate: 5, leave: 3, spawn_child: 4, child_status: 3,
                      terminate_child: 4
end

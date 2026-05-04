defmodule LLMAgent.Tool.Kinds.Action do
  @moduledoc """
  The `:action` kind. Side effects; not retryable without idempotency.

  Use `:action` when the tool mutates external state (writes a file, sends a
  message, creates a resource). The agent must not blindly retry an action call
  without an idempotency key; the `idempotency_key` argument is the hook for
  safe retry. If the implementation is purely read-only use `:query` instead.

  See `docs/superpowers/specs/2026-05-03-tool-discovery-design.md` §3.2.

  ## Minimal implementation

  Implement `@behaviour LLMAgent.Tool.Kinds.Action` and define `act/3`:

  ```elixir
  @behaviour LLMAgent.Tool.Kinds.Action

  @impl true
  def act("send_message", %{"body" => body}, _key), do: {:ok, :sent, %{}}
  def act(_, _, _), do: {:error, :unknown_action}
  ```
  """

  @typedoc "Acknowledgement returned from an action. Implementation-defined."
  @type ack :: term()

  @typedoc "Metadata accompanying an action result."
  @type meta :: map()

  @typedoc "Error reason. Any term — atom, struct, tagged tuple."
  @type error_reason :: term()

  @typedoc """
  Return value of a successful action: `{:ok, ack, meta}` where `ack` is an
  acknowledgement token (receipt ID, `:ok`, etc.) and `meta` is an open map.
  On failure: `{:error, reason}`.
  """
  @type result :: {:ok, ack(), meta()} | {:error, error_reason()}

  @doc "Execute an action with side effects. Accepts optional idempotency_key to prevent duplicate effects. Returns `{:ok, ack, meta}` on success or `{:error, reason}` on failure."
  @callback act(action :: String.t(), args :: map(), idempotency_key :: String.t() | nil) ::
              result()
end

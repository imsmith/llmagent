defmodule LLMAgent.Tool.Kinds.Compute do
  @moduledoc """
  The `:compute` kind. Pure transformation; no I/O.

  A `:compute` tool is deterministic in its inputs, freely retryable, freely
  cacheable, and movable to any node. The strictest kind — its purity is a
  load-bearing invariant the agent can rely on. If the implementation needs
  any I/O, idempotency keys, or side-effect metadata, the right kind is
  `:query` or `:action`, not `:compute`.

  See `docs/superpowers/specs/2026-05-03-tool-discovery-design.md` §3.4.

  ## Minimal implementation

  Implement `@behaviour LLMAgent.Tool.Kinds.Compute` and define `compute/2`:

  ```elixir
  @behaviour LLMAgent.Tool.Kinds.Compute

  @impl true
  def compute("sha256", %{"data" => data}),
    do: {:ok, Base.encode16(:crypto.hash(:sha256, data))}
  def compute(_, _), do: {:error, :unknown_action}
  ```
  """

  @doc "Execute a pure computation over args. No I/O, no side effects. Returns `{:ok, value}` on success or `{:error, reason}` on failure."
  @callback compute(action :: String.t(), args :: map()) ::
              {:ok, value :: term()} | {:error, atom()}
end

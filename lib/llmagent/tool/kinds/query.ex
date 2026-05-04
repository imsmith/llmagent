defmodule LLMAgent.Tool.Kinds.Query do
  @moduledoc """
  The `:query` kind. Pure read; no side effects; idempotent.

  Use `:query` when the tool retrieves information without modifying any state.
  The agent may freely retry, cache, and parallelize query calls. If the
  implementation touches writable state, the correct kind is `:action`.

  See `docs/superpowers/specs/2026-05-03-tool-discovery-design.md` §3.1.

  ## Minimal implementation

  Implement `@behaviour LLMAgent.Tool.Kinds.Query` and define `query/2`:

  ```elixir
  @behaviour LLMAgent.Tool.Kinds.Query

  @impl true
  def query("list_interfaces", _args), do: {:ok, [:eth0, :lo], %{}}
  def query(_, _), do: {:error, :unknown_action}
  ```
  """

  @typedoc """
  Return value of a successful query: `{:ok, value, meta}` where `meta` is an
  open map for provenance, timing, or pagination context. On failure:
  `{:error, reason}`.
  """
  @type result :: {:ok, value :: term(), meta :: map()} | {:error, term()}

  @doc "Execute a read-only query. Pure, idempotent, no side effects. Returns `{:ok, value, meta}` on success or `{:error, reason}` on failure."
  @callback query(action :: String.t(), args :: map()) ::
              {:ok, value :: term(), meta :: map()} | {:error, atom()}
end

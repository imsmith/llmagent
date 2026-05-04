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

  @typedoc "Value returned from a query. Implementation-defined shape."
  @type value :: term()

  @typedoc "Metadata accompanying a query result. Implementation-defined keys."
  @type meta :: map()

  @typedoc "Error reason. May be atom, struct (e.g. Comn.Errors.ErrorStruct), tuple, or any term."
  @type error_reason :: term()

  @typedoc """
  Return value of a successful query: `{:ok, value, meta}` where `meta` is an
  open map for provenance, timing, or pagination context. On failure:
  `{:error, reason}`.
  """
  @type result :: {:ok, value(), meta()} | {:error, error_reason()}

  @doc "Execute a read-only query. Pure, idempotent, no side effects. Returns `{:ok, value, meta}` on success or `{:error, reason}` on failure."
  @callback query(action :: String.t(), args :: map()) ::
              result()
end

defmodule LLMAgent.Tool.Kinds.Generate do
  @moduledoc """
  The `:generate` kind. Stochastic, retryable, not cacheable.

  A `:generate` tool produces an output from a prompt where re-running with
  identical inputs may produce different outputs (LLM completion, image
  generation, etc.). The agent may retry safely, but must not cache results
  by input hash.

  Distinct from `:compute` (pure, deterministic) and `:query` (idempotent
  read). The result tuple carries an explicit `provenance` map for model id,
  latency, token counts, and any other observation that downstream consumers
  (trained-ad lifecycle, billing, fairness) may want to use.

  See `docs/superpowers/specs/2026-05-07-mdns-llm-discovery.md`.

  ## Minimal implementation

  ```elixir
  @behaviour LLMAgent.Tool.Kinds.Generate

  @impl true
  def generate("chat", %{messages: msgs}) do
    {:ok, "hello, world", %{model: "stub", latency_ms: 1}}
  end
  ```
  """

  @typedoc "Generated value. Implementation-defined shape (typically a string for chat)."
  @type value :: term()

  @typedoc """
  Per-call provenance: `:model`, `:latency_ms`, `:tokens_in`, `:tokens_out`,
  and any implementation-specific observations. Open map.
  """
  @type provenance :: map()

  @typedoc "Error reason. Any term."
  @type error_reason :: term()

  @typedoc "Result of a successful generation: `{:ok, value, provenance}`. On failure: `{:error, reason}`."
  @type result :: {:ok, value(), provenance()} | {:error, error_reason()}

  @doc "Produce a stochastic output. Retryable but not cacheable. Returns `{:ok, value, provenance}` on success or `{:error, reason}` on failure."
  @callback generate(action :: String.t(), args :: map()) :: result()
end

defmodule LLMAgent.Tool.Adapter do
  @moduledoc """
  Behaviour for binding adapters. Adapters bridge from a binding payload to a
  kind-shaped invocation. Each callback mirrors a kind's contract with the
  binding payload as the first argument.

  A binding payload is the second element of a `ToolAd.binding` tuple —
  for a `:module` binding it is the module atom; for a `:process` binding it
  would be a pid; for `:http` a URL base string, etc. The adapter's job is to
  translate the payload + kind arguments into whatever the underlying binding
  actually needs.

  Adapters implement only the kinds their binding can carry. All callbacks are
  optional — the dispatcher checks `function_exported?` before calling. If a
  kind is not supported, the ad should not declare that kind in `ToolAd.kinds`.

  See `docs/superpowers/specs/2026-05-03-tool-discovery-design.md` §4.1.

  ## Minimal example adapter

  An adapter that handles only `:compute` calls via an in-process function:

  ```elixir
  @behaviour LLMAgent.Tool.Adapter

  @impl true
  def compute(fun, action, args, _opts) when is_function(fun, 2),
    do: fun.(action, args)
  ```

  Register it with `LLMAgent.Tool.Bindings.register(:fun, __MODULE__)` and
  use `binding: {:fun, &my_fn/2}` in any `ToolAd` pointing at it.
  """

  @typedoc "Opaque binding payload — second element of `ToolAd.binding` tuple. Adapter-specific."
  @type payload :: term()

  @typedoc "Opaque child reference returned by `spawn_child/3`. Adapter-specific."
  @type child_ref :: term()

  @typedoc "Spec passed to `spawn_child/3`. Adapter-specific."
  @type child_spec :: term()

  @typedoc "Termination reason for `terminate_child/4`. Any term."
  @type terminate_reason :: term()

  @typedoc "Value returned from successful query/compute. Implementation-defined."
  @type value :: term()

  @typedoc "Acknowledgement from successful action. Implementation-defined."
  @type ack :: term()

  @typedoc "Metadata accompanying a successful result. Implementation-defined keys."
  @type meta :: map()

  @typedoc "Error reason. May be atom, struct (e.g. Comn.Errors.ErrorStruct), tuple, or any term."
  @type error_reason :: term()

  @typedoc "Status returned from `child_status/3`. Implementation-defined."
  @type child_status :: term()

  @doc "Execute a read-only query. Pure, idempotent, no side effects."
  @callback query(payload(), action :: String.t(), args :: map(),
                  opts :: keyword()) ::
              {:ok, value(), meta()} | {:error, error_reason()}

  @doc "Execute an action with side effects. Accepts optional idempotency_key to prevent duplicate effects."
  @callback act(payload(), action :: String.t(), args :: map(),
                idempotency_key :: String.t() | nil, opts :: keyword()) ::
              {:ok, ack(), meta()} | {:error, error_reason()}

  @doc "Subscribe to stream updates."
  @callback subscribe(payload(), action :: String.t(), args :: map(),
                      subscriber :: pid(), opts :: keyword()) ::
              {:ok, reference()} | {:error, error_reason()}

  @doc "Unsubscribe from stream updates."
  @callback unsubscribe(payload(), sub_ref :: reference(),
                        opts :: keyword()) :: :ok

  @doc "Compute a pure value — no I/O, no side effects."
  @callback compute(payload(), action :: String.t(), args :: map(),
                    opts :: keyword()) ::
              {:ok, value()} | {:error, error_reason()}

  @doc "Produce a stochastic output. Retryable but not cacheable."
  @callback generate(payload(), action :: String.t(), args :: map(),
                     opts :: keyword()) ::
              {:ok, value(), meta()} | {:error, error_reason()}

  @doc "Participate in a coordination session."
  @callback participate(payload(), role :: atom(), args :: map(),
                        opts :: keyword()) ::
              {:ok, reference()} | {:error, error_reason()}

  @doc "Leave a coordination session."
  @callback leave(payload(), participation_ref :: reference(),
                  opts :: keyword()) :: :ok

  @doc "Spawn a child process."
  @callback spawn_child(payload(), spec :: child_spec(),
                        opts :: keyword()) ::
              {:ok, child_ref()} | {:error, error_reason()}

  @doc "Query the status of a child process."
  @callback child_status(payload(), child_ref :: child_ref(),
                         opts :: keyword()) :: child_status()

  @doc "Terminate a child process with the given reason."
  @callback terminate_child(payload(), child_ref :: child_ref(),
                            reason :: terminate_reason(), opts :: keyword()) ::
              :ok | {:error, error_reason()}

  @optional_callbacks query: 4, act: 5, subscribe: 5, unsubscribe: 3, compute: 4,
                      generate: 4, participate: 4, leave: 3, spawn_child: 3,
                      child_status: 3, terminate_child: 4
end

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

  @typedoc "Opaque binding payload — the second element of a `ToolAd.binding` tuple. Shape is adapter-specific."
  @type payload :: module() | pid() | reference() | binary() | map()

  @typedoc "Opaque child reference returned by `spawn_child/3`. Shape is adapter-specific."
  @type child_ref :: pid() | reference() | binary()

  @typedoc "Opaque child spec passed to `spawn_child/3`. Shape is adapter-specific."
  @type child_spec :: map() | keyword() | binary()

  @typedoc "Termination reason passed to `terminate_child/4`."
  @type reason :: atom() | {:shutdown, atom()}

  @typedoc "Value returned from a successful query or compute call."
  @type value :: map() | list() | binary() | number() | boolean() | nil

  @typedoc "Acknowledgement token returned from a successful action call."
  @type ack :: map() | binary() | atom()

  @doc "Execute a read-only query. Pure, idempotent, no side effects."
  @callback query(payload(), action :: String.t(), args :: map(),
                  opts :: keyword()) ::
              {:ok, value(), map()} | {:error, atom()}

  @doc "Execute an action with side effects. Accepts optional idempotency_key to prevent duplicate effects."
  @callback act(payload(), action :: String.t(), args :: map(),
                idempotency_key :: String.t() | nil, opts :: keyword()) ::
              {:ok, ack(), map()} | {:error, atom()}

  @doc "Subscribe to stream updates."
  @callback subscribe(payload(), action :: String.t(), args :: map(),
                      subscriber :: pid(), opts :: keyword()) ::
              {:ok, reference()} | {:error, atom()}

  @doc "Unsubscribe from stream updates."
  @callback unsubscribe(payload(), sub_ref :: reference(),
                        opts :: keyword()) :: :ok

  @doc "Compute a pure value — no I/O, no side effects."
  @callback compute(payload(), action :: String.t(), args :: map(),
                    opts :: keyword()) ::
              {:ok, value()} | {:error, atom()}

  @doc "Participate in a coordination session."
  @callback participate(payload(), role :: atom(), args :: map(),
                        opts :: keyword()) ::
              {:ok, reference()} | {:error, atom()}

  @doc "Leave a coordination session."
  @callback leave(payload(), participation_ref :: reference(),
                  opts :: keyword()) :: :ok

  @doc "Spawn a child process."
  @callback spawn_child(payload(), spec :: child_spec(),
                        opts :: keyword()) ::
              {:ok, child_ref()} | {:error, atom()}

  @doc "Query the status of a child process."
  @callback child_status(payload(), child_ref :: child_ref(),
                         opts :: keyword()) :: atom() | map()

  @doc "Terminate a child process with the given reason."
  @callback terminate_child(payload(), child_ref :: child_ref(),
                            reason(), opts :: keyword()) ::
              :ok | {:error, atom()}

  @optional_callbacks query: 4, act: 5, subscribe: 5, unsubscribe: 3, compute: 4,
                      participate: 4, leave: 3, spawn_child: 3, child_status: 3,
                      terminate_child: 4
end

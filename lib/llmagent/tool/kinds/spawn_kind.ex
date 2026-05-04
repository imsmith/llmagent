defmodule LLMAgent.Tool.Kinds.SpawnKind do
  @moduledoc """
  The `:spawn` kind. Parent-child lifecycle ownership.

  Use `:spawn` when the tool starts a long-lived child process whose lifecycle
  the caller owns: subagents, background jobs, managed containers. The caller
  receives a `child_ref`, polls status via `child_status/1`, and terminates via
  `terminate_child/2`. The tool implementation is responsible for cleanup on
  termination.

  This module is named `SpawnKind` to avoid collision with `Kernel.spawn/1` in
  callers. The kind atom in `ToolAd.kinds` is still `:spawn`.

  See `docs/superpowers/specs/2026-05-03-tool-discovery-design.md` §3.6.

  ## Minimal implementation

  Implement `@behaviour LLMAgent.Tool.Kinds.SpawnKind` and define
  `spawn_child/2`, `child_status/1`, and `terminate_child/2`:

  ```elixir
  @behaviour LLMAgent.Tool.Kinds.SpawnKind

  @impl true
  def spawn_child(spec, _opts) do
    pid = start_child_process(spec)
    {:ok, pid}
  end

  @impl true
  def child_status(pid), do: Process.alive?(pid) && :running || :stopped

  @impl true
  def terminate_child(pid, _reason) do
    Process.exit(pid, :shutdown)
    :ok
  end
  ```
  """

  @typedoc "Opaque reference returned by `spawn_child/2` and passed to status/terminate callbacks."
  @type child_ref :: pid() | reference() | binary()

  @typedoc "Implementation-defined child specification passed to `spawn_child/2`."
  @type child_spec :: map() | keyword() | binary()

  @typedoc "Status value returned by `child_status/1`. Shape is implementation-defined."
  @type child_status :: :running | :stopped | :error | atom()

  @doc "Spawn a child process from a spec. Returns `{:ok, child_ref}` or `{:error, reason}` on failure."
  @callback spawn_child(spec :: child_spec(), opts :: keyword()) ::
              {:ok, child_ref()} | {:error, atom()}

  @doc "Query the status of a child process. Returns an implementation-defined status value."
  @callback child_status(child_ref :: child_ref()) :: child_status()

  @doc "Terminate a child process with the given reason. Returns `:ok` or `{:error, reason}` on failure."
  @callback terminate_child(child_ref :: child_ref(), reason :: atom()) ::
              :ok | {:error, atom()}
end

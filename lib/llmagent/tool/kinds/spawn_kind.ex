defmodule LLMAgent.Tool.Kinds.SpawnKind do
  @moduledoc """
  The `:spawn` kind. Parent-child lifecycle ownership.

  This module is named `SpawnKind` to avoid collision with `Kernel.spawn/1` in callers.
  The kind atom in `ToolAd.kinds` is still `:spawn`.

  See spec §3.6.
  """

  @doc "Spawn a child process. Returns `{:ok, child_ref}` or `{:error, reason}` on failure."
  @callback spawn_child(spec :: term(), opts :: keyword()) ::
              {:ok, child_ref :: term()} | {:error, term()}

  @doc "Query the status of a child process."
  @callback child_status(child_ref :: term()) :: term()

  @doc "Terminate a child process with the given reason. Returns `:ok` or `{:error, reason}` on failure."
  @callback terminate_child(child_ref :: term(), reason :: term()) ::
              :ok | {:error, term()}
end


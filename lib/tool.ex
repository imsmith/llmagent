defmodule LLMAgent.Tool do
  @moduledoc """
  Umbrella behaviour for LLMAgent tools.

  New tools implement `ad/0` returning their authoritative `LLMAgent.ToolAd`,
  plus one or more kind behaviours from `LLMAgent.Tool.Kinds.*`.

  The legacy `describe/0` + `perform/2` callbacks remain optional and
  deprecated; they are kept until all existing tools have migrated. See
  the spec at `docs/superpowers/specs/2026-05-03-tool-discovery-design.md`
  for the migration plan.
  """

  @type tool_result ::
          {:ok, %{output: term(), metadata: map()}}
          | {:error, Comn.Errors.ErrorStruct.t()}

  @doc """
  Returns the authoritative tool advertisement for this tool.

  New tools must implement this callback. Legacy tools may omit it during migration.
  """
  @callback ad() :: LLMAgent.ToolAd.t()

  @doc """
  Returns a human-readable description of this tool.

  Legacy callback; deprecated in favor of `ad/0`. Tools should eventually migrate
  to the full advertisement structure.
  """
  @deprecated "Use ad/0 with kind behaviours instead. See migration plan."
  @callback describe() :: String.t()

  @doc """
  Performs a named action with the given arguments.

  Returns `{:ok, %{output: term(), metadata: map()}}` on success or
  `{:error, Comn.Errors.ErrorStruct.t()}` on failure.

  Legacy callback; deprecated in favor of the kind-based action system.
  """
  @deprecated "Use the appropriate kind behaviour callback instead. See migration plan."
  @callback perform(action :: String.t(), args :: map()) :: tool_result()

  @optional_callbacks ad: 0, describe: 0, perform: 2
end

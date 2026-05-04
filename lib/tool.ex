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

  @doc "Return the authoritative tool advertisement. New tools implement this; legacy tools may omit during migration."
  @callback ad() :: LLMAgent.ToolAd.t()

  @doc "DEPRECATED. Human-readable description; superseded by ad/0. Kept until existing tools migrate."
  @callback describe() :: String.t()

  @doc "DEPRECATED. Perform a named action; superseded by per-kind callbacks. Kept until existing tools migrate."
  @callback perform(action :: String.t(), args :: map()) :: tool_result()

  @optional_callbacks ad: 0, describe: 0, perform: 2
end

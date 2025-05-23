defmodule LLMAgent.Tool do
@moduledoc """
Behaviour for all LLMAgent tool modules.

Each tool must:
  - Provide a `describe/0` function that returns a human-readable summary
  - Implement `perform/2` to handle a named action and parameter map
"""

  @callback describe() :: String.t()
  @callback perform(action :: String.t(), args :: map()) :: any()
end

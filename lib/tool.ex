defmodule LLMAgent.Tool do
  @moduledoc """
  Behaviour for all LLMAgent tool modules.

  Each tool must:
    - Provide a `describe/0` function that returns a human-readable summary
    - Implement `perform/2` to handle a named action and parameter map

  All `perform/2` implementations must return `tool_result()`.

  ## Examples

  Implementing a tool:

      defmodule MyTool do
        @behaviour LLMAgent.Tool

        @impl true
        def describe, do: "Does something useful."

        @impl true
        def perform("go", %{"input" => val}) do
          {:ok, %{output: val, metadata: %{action: "go"}}}
        end

        def perform(_, _) do
          {:error, Comn.Errors.ErrorStruct.new("unknown_command", nil, "Unknown action")}
        end
      end
  """

  @type tool_result ::
          {:ok, %{output: term(), metadata: map()}}
          | {:error, Comn.Errors.ErrorStruct.t()}

  @callback describe() :: String.t()
  @callback perform(action :: String.t(), args :: map()) :: tool_result()
end

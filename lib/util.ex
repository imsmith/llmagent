defmodule LLMAgent.Util do
  @moduledoc """
  Behaviour for pluggable utility modules.

  Each utility must:
    - provide a human-readable description
    - list its callable capabilities
    - implement a dispatcher for named actions

  ## Examples

  Implementing a utility:

      defmodule MyUtil do
        @behaviour LLMAgent.Util

        @impl true
        def describe, do: "Formats things."

        @impl true
        def capabilities, do: ["upcase"]

        @impl true
        def call("upcase", %{"text" => t}), do: {:ok, String.upcase(t)}
        def call(_, _), do: {:error, :unsupported}
      end
  """

  @callback describe() :: String.t()
  @callback capabilities() :: list(String.t())
  @callback call(String.t(), map()) :: {:ok, any()} | {:error, any()}
end

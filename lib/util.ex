defmodule LLMAgent.Util do
  @moduledoc """
  Defines the required interface for pluggable utility modules.

  Each utility must:
    - provide a human-readable description
    - list its callable capabilities
    - implement a dispatcher for named actions
  """

  @callback describe() :: String.t()
  @callback capabilities() :: list(String.t())
  @callback call(String.t(), map()) :: {:ok, any()} | {:error, any()}
end

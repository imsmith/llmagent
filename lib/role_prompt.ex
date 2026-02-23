defmodule LLMAgent.RolePrompt do
  @moduledoc """
  Prompt registry for different agent roles.

  ## Examples

      iex> LLMAgent.RolePrompt.get(:default)
      "You are a helpful assistant."

      iex> LLMAgent.RolePrompt.get(:sysadmin) |> String.contains?("Linux")
      true
  """

  @doc """
  Returns the system prompt for a given role.

  ## Examples

      iex> LLMAgent.RolePrompt.get(:default)
      "You are a helpful assistant."

      iex> LLMAgent.RolePrompt.get(nil)
      "You are a helpful assistant."
  """
  def get(:sysadmin), do: LLMAgent.Prompts.Sysadmin.prompt()
  def get(:default), do: LLMAgent.Prompts.Default.prompt()
  def get(nil), do: get(:default)
  def get(role) do
    IO.warn("Unknown role #{inspect(role)} — falling back to default")
    get(:default)
  end
end

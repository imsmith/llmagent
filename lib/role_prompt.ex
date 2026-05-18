defmodule LLMAgent.RolePrompt do
  @moduledoc """
  Prompt registry for different agent roles.

  ## Examples

      iex> LLMAgent.RolePrompt.get(:default)
      "You are a helpful assistant."

      iex> LLMAgent.RolePrompt.get(:sysadmin) |> String.contains?("Linux")
      true

      iex> :default in LLMAgent.RolePrompt.roles()
      true
  """

  @registry %{
    default: LLMAgent.Prompts.Default,
    sysadmin: LLMAgent.Prompts.Sysadmin
  }

  @doc """
  Returns the list of registered role atoms.

  ## Examples

      iex> LLMAgent.RolePrompt.roles() |> Enum.sort()
      [:default, :sysadmin]
  """
  @spec roles() :: [atom()]
  def roles, do: Map.keys(@registry)

  @doc """
  Returns the system prompt for a given role.

  ## Examples

      iex> LLMAgent.RolePrompt.get(:default)
      "You are a helpful assistant."

      iex> LLMAgent.RolePrompt.get(nil)
      "You are a helpful assistant."
  """
  for {role, mod} <- @registry do
    def get(unquote(role)), do: unquote(mod).prompt()
  end

  def get(nil), do: get(:default)

  def get(role) do
    IO.warn("Unknown role #{inspect(role)} — falling back to default")
    get(:default)
  end
end

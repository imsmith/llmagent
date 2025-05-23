defmodule LLMAgent.RolePrompt do
  @moduledoc "Prompt registry for different agent roles"

  def get(:sysadmin), do: LLMAgent.Prompts.Sysadmin.prompt()
  def get(:default), do: LLMAgent.Prompts.Default.prompt()
  def get(nil), do: get(:default)
  def get(role) do
    IO.warn("Unknown role #{inspect(role)} — falling back to default")
    get(:default)
  end
end

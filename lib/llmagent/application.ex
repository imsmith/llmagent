defmodule LLMAgent.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    check_system_requirements()

    agent_opts = [
      name: LLMAgent,
      model: Application.get_env(:LLMAgent, :model, "gpt-4"),
      api_host: Application.get_env(:LLMAgent, :api_host, "http://localhost:4000"),
      role: parse_role(Application.get_env(:LLMAgent, :role, "default"))
    ]

    children = [
      {Task.Supervisor, name: LLMAgent.TaskSup},
      {LLMAgent, agent_opts},
      {Registry, keys: :duplicate, name: LLMAgent.EventBus},
      {LLMAgent.EventLog, []}
    ]

    opts = [strategy: :one_for_one, name: LLMAgent.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp parse_role(role) when is_atom(role), do: role
  defp parse_role(role) when is_binary(role), do: String.to_atom(role)

  defp check_system_requirements do
    required = ["wg", "ssh-keygen", "gpg"]
    missing = Enum.reject(required, &System.find_executable/1)

    unless missing == [] do
      require Logger
      Logger.warning("Optional binaries not found: #{Enum.join(missing, ", ")}")
    end
  end
end

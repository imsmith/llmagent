defmodule LLMAgent.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    check_system_requirements()

    children = [
      {Task.Supervisor, name: LLMAgent.TaskSup},
      {LLMAgent, name: LLMAgent},
      {Registry, keys: :duplicate, name: LLMAgent.EventBus},
      {LLMAgent.EventLog, []}
    ]

    opts = [strategy: :one_for_one, name: LLMAgent.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp check_system_requirements do
    required = ["wg", "ssh-keygen", "gpg"]
    missing = Enum.reject(required, &System.find_executable/1)

    unless missing == [] do
      require Logger
      Logger.warning("Optional binaries not found: #{Enum.join(missing, ", ")}")
    end
  end
end

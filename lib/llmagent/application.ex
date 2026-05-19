defmodule LLMAgent.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    check_system_requirements()
    LLMAgent.Tools.init_registry()
    LLMAgent.Tool.Kinds.init_registry()
    LLMAgent.Tool.Bindings.init_registry()
    LLMAgent.Tool.Dispatcher.init_approvals()

    agent_opts = [
      name: LLMAgent,
      model: Application.get_env(:LLMAgent, :model, "gpt-4"),
      api_host: Application.get_env(:LLMAgent, :api_host, "http://localhost:11434/v1"),
      role: parse_role(Application.get_env(:LLMAgent, :role, "default"))
    ]

    children = [
      {Task.Supervisor, name: LLMAgent.TaskSup},
      {LLMAgent.Tools.Inotify.Watcher, []},
      {DynamicSupervisor, name: LLMAgent.AgentSupervisor, strategy: :one_for_one},
      {Registry, keys: :duplicate, name: LLMAgent.EventBus},
      {LLMAgent.EventLog, []},
      {LLMAgent.DurableLog, []},
      {Registry, keys: :unique, name: LLMAgent.MCP.Registry},
      {DynamicSupervisor, name: LLMAgent.MCP.ConnectionSupervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: LLMAgent.TupleSpace.Registry},
      {DynamicSupervisor, name: LLMAgent.TupleSpace.Supervisor, strategy: :one_for_one},
      {LLMAgent.Tools.Discovery, []},
      {LLMAgent.Discovery.AdapterSupervisor, []}
    ]

    opts = [strategy: :one_for_one, name: LLMAgent.Supervisor]
    {:ok, sup} = Supervisor.start_link(children, opts)

    Enum.each(
      Application.get_env(:LLMAgent, :discovery_adapters, []),
      &LLMAgent.Discovery.AdapterSupervisor.start_adapter/1
    )

    LLMAgent.Tools.Builtins.register_all()
    LLMAgent.AgentSupervisor.start_agent(agent_opts)
    LLMAgent.TupleSpace.start_space(:default)
    {:ok, sup}
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

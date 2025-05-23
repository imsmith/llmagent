defmodule LLMAgent.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Starts a worker by calling: LLMAgent.Worker.start_link(arg)
      # {LLMAgent.Worker, arg}
      {Task.Supervisor, name: LLMAgent.TaskSup},
      {LLMAgent, name: LLMAgent},
      {Registry, keys: :duplicate, name: LLMAgent.EventBus},
      {LLMAgent.EventLog, []}

    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: LLMAgent.Supervisor]

    with :ok <- validate_system_requirements!() do
      Supervisor.start_link(children, opts)
    end

  end

  def validate_system_requirements! do
    case LLMAgent.Utils.RequireBinary.check_many(["wg", "ssh-keygen", "gpg"]) do
      :ok -> :ok
      {:error, msgs} ->
        {:error, {:missing_binaries, msgs}}
    end
  end

end

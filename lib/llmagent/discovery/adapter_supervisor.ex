defmodule LLMAgent.Discovery.AdapterSupervisor do
  @moduledoc """
  `DynamicSupervisor` for `LLMAgent.Discovery.PortAdapter` children.

  At application boot, `LLMAgent.Application` reads the `:discovery_adapters`
  config list and calls `start_adapter/1` for each entry. The supervisor
  uses a `:one_for_one` restart strategy: a misbehaving shim can crash and
  restart without affecting other discovery sources.
  """

  use DynamicSupervisor

  alias LLMAgent.Discovery.PortAdapter

  @doc "Start the supervisor, registered locally under this module name."
  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_arg) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Start a `PortAdapter` child from a config map. The map must include `:name` and `:command`."
  @spec start_adapter(map()) :: DynamicSupervisor.on_start_child()
  def start_adapter(%{name: _, command: _} = spec) do
    opts = spec |> Map.to_list()
    DynamicSupervisor.start_child(__MODULE__, {PortAdapter, opts})
  end
end

defmodule LLMAgent.AgentSupervisor do
  @moduledoc """
  DynamicSupervisor for managing multiple concurrent agent processes.

  ## Examples

      iex> name = String.to_atom("doctest_sup_" <> Integer.to_string(System.unique_integer([:positive])))
      iex> {:ok, pid} = LLMAgent.AgentSupervisor.start_agent(name: name)
      iex> is_pid(pid)
      true
      iex> DynamicSupervisor.terminate_child(LLMAgent.AgentSupervisor, pid)
      :ok
  """

  @doc """
  Start a new agent under the DynamicSupervisor.

  ## Examples

      iex> name = String.to_atom("doctest_start_" <> Integer.to_string(System.unique_integer([:positive])))
      iex> {:ok, pid} = LLMAgent.AgentSupervisor.start_agent(name: name, role: :default)
      iex> Process.alive?(pid)
      true
      iex> DynamicSupervisor.terminate_child(LLMAgent.AgentSupervisor, pid)
  """
  def start_agent(opts) do
    DynamicSupervisor.start_child(__MODULE__, {LLMAgent, opts})
  end

  @doc """
  Stop a running agent by name.

  ## Examples

      iex> name = String.to_atom("doctest_stop_" <> Integer.to_string(System.unique_integer([:positive])))
      iex> {:ok, _} = LLMAgent.AgentSupervisor.start_agent(name: name)
      iex> LLMAgent.AgentSupervisor.stop_agent(name)
      :ok

      iex> LLMAgent.AgentSupervisor.stop_agent(:nonexistent_doctest_agent)
      {:error, :not_found}
  """
  def stop_agent(name) do
    case GenServer.whereis({:global, name}) do
      nil -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end

  @doc """
  List PIDs of all running agents.

  ## Examples

      iex> is_list(LLMAgent.AgentSupervisor.list_agents())
      true
  """
  def list_agents do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&is_pid/1)
  end
end

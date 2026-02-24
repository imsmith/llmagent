defmodule LLMAgent.Memory.ETS do
  @moduledoc """
  ETS-backed memory backend using Comn.Repo.Table.ETS.

  Each agent gets its own ETS table named `:"llmagent_mem_\#{agent_id}"`.

  ## Examples

      iex> alias LLMAgent.Memory.ETS
      iex> id = String.to_atom("doctest_mem_" <> Integer.to_string(System.unique_integer([:positive])))
      iex> :ok = ETS.init(id)
      iex> :ok = ETS.store(id, :key, "value")
      iex> {:ok, "value"} = ETS.fetch(id, :key)
      iex> ETS.teardown(id)
      :ok

      iex> alias LLMAgent.Memory.ETS
      iex> id = String.to_atom("doctest_mem2_" <> Integer.to_string(System.unique_integer([:positive])))
      iex> ETS.init(id)
      iex> ETS.fetch(id, :missing)
      {:error, :not_found}
      iex> ETS.teardown(id)
      :ok
  """

  @behaviour LLMAgent.Memory
  alias Comn.Repo.Table.ETS, as: Table

  @doc """
  Initialize the memory table for an agent. Idempotent.

  ## Examples

      iex> id = String.to_atom("doctest_init_" <> Integer.to_string(System.unique_integer([:positive])))
      iex> :ok = LLMAgent.Memory.ETS.init(id)
      iex> :ok = LLMAgent.Memory.ETS.init(id)
      iex> LLMAgent.Memory.ETS.teardown(id)
      :ok
  """
  @impl true
  def init(agent_id, _opts \\ []) do
    case Table.create(table_for(agent_id)) do
      {:ok, _} -> :ok
      {:error, {:already_exists, _}} -> :ok
    end
  end

  @doc """
  Store a key-value pair.

  ## Examples

      iex> id = String.to_atom("doctest_store_" <> Integer.to_string(System.unique_integer([:positive])))
      iex> LLMAgent.Memory.ETS.init(id)
      iex> LLMAgent.Memory.ETS.store(id, :history, [%{role: "system", content: "hi"}])
      :ok
      iex> LLMAgent.Memory.ETS.teardown(id)
  """
  @impl true
  def store(agent_id, key, value) do
    Table.set(table_for(agent_id), key: key, value: value)
  end

  @doc """
  Fetch a value by key.

  ## Examples

      iex> id = String.to_atom("doctest_fetch_" <> Integer.to_string(System.unique_integer([:positive])))
      iex> LLMAgent.Memory.ETS.init(id)
      iex> LLMAgent.Memory.ETS.store(id, :name, "agent1")
      iex> LLMAgent.Memory.ETS.fetch(id, :name)
      {:ok, "agent1"}
      iex> LLMAgent.Memory.ETS.fetch(id, :nope)
      {:error, :not_found}
      iex> LLMAgent.Memory.ETS.teardown(id)
  """
  @impl true
  def fetch(agent_id, key) do
    case Table.get(table_for(agent_id), key: key) do
      {:ok, value} -> {:ok, value}
      {:error, {:not_found, _}} -> {:error, :not_found}
    end
  end

  @doc """
  Delete a key.

  ## Examples

      iex> id = String.to_atom("doctest_del_" <> Integer.to_string(System.unique_integer([:positive])))
      iex> LLMAgent.Memory.ETS.init(id)
      iex> LLMAgent.Memory.ETS.store(id, :tmp, "gone")
      iex> LLMAgent.Memory.ETS.delete(id, :tmp)
      :ok
      iex> LLMAgent.Memory.ETS.fetch(id, :tmp)
      {:error, :not_found}
      iex> LLMAgent.Memory.ETS.teardown(id)
  """
  @impl true
  def delete(agent_id, key) do
    Table.delete(table_for(agent_id), key: key)
  end

  @doc """
  List all key-value pairs.

  ## Examples

      iex> id = String.to_atom("doctest_list_" <> Integer.to_string(System.unique_integer([:positive])))
      iex> LLMAgent.Memory.ETS.init(id)
      iex> LLMAgent.Memory.ETS.store(id, :a, 1)
      iex> LLMAgent.Memory.ETS.store(id, :b, 2)
      iex> {:ok, entries} = LLMAgent.Memory.ETS.list(id)
      iex> length(entries)
      2
      iex> LLMAgent.Memory.ETS.teardown(id)
  """
  @impl true
  def list(agent_id) do
    case Table.observe(table_for(agent_id), []) do
      entries when is_list(entries) -> {:ok, entries}
      {:error, _} = err -> err
    end
  end

  @doc """
  Destroy the agent's memory table.

  ## Examples

      iex> id = String.to_atom("doctest_tear_" <> Integer.to_string(System.unique_integer([:positive])))
      iex> LLMAgent.Memory.ETS.init(id)
      iex> LLMAgent.Memory.ETS.teardown(id)
      :ok
  """
  @impl true
  def teardown(agent_id) do
    Table.drop(table_for(agent_id))
    :ok
  end

  defp table_for(id), do: :"llmagent_mem_#{id}"
end

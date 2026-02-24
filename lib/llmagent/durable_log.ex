defmodule LLMAgent.DurableLog do
  @moduledoc """
  DETS-backed durable event log.

  Persists all events emitted through `LLMAgent.Events.emit/4` to disk.
  Provides query API for retrieving events and reconstructing agent history.

  ## Examples

      iex> LLMAgent.DurableLog.clear()
      :ok
      iex> event = Comn.Events.EventStruct.new(:message, "agent.message", %{agent_id: :doc_agent, role: "user", content: "hello"}, :doctest)
      iex> LLMAgent.DurableLog.record(event)
      :ok
      iex> LLMAgent.DurableLog.messages_for(:doc_agent)
      [%{role: "user", content: "hello"}]
      iex> LLMAgent.DurableLog.clear()
      :ok
  """

  use GenServer

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Record an event to durable storage."
  def record(event) do
    GenServer.cast(__MODULE__, {:record, event})
  end

  @doc "Return message history for an agent as `[%{role, content}]`."
  def messages_for(agent_id) do
    GenServer.call(__MODULE__, {:messages_for, agent_id})
  end

  @doc "Return all events for an agent, sorted by timestamp."
  def events_for(agent_id) do
    GenServer.call(__MODULE__, {:events_for, agent_id})
  end

  @doc "Return events for an agent since a given ISO 8601 timestamp."
  def events_for(agent_id, since: iso_timestamp) do
    GenServer.call(__MODULE__, {:events_for, agent_id, since: iso_timestamp})
  end

  @doc "Clear all events for a specific agent."
  def clear(agent_id) do
    GenServer.call(__MODULE__, {:clear, agent_id})
  end

  @doc "Clear all events."
  def clear do
    GenServer.call(__MODULE__, :clear_all)
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :data_dir, "data")
    File.mkdir_p!(dir)
    path = Path.join(dir, "llmagent_events.dets") |> String.to_charlist()

    {:ok, tab} =
      :dets.open_file(:llmagent_durable_log, [
        {:file, path},
        {:type, :duplicate_bag},
        {:auto_save, 30_000}
      ])

    {:ok, %{tab: tab}}
  end

  @impl true
  def handle_cast({:record, event}, state) do
    agent_id = extract_agent_id(event)
    :dets.insert(state.tab, {agent_id, event})
    {:noreply, state}
  end

  @impl true
  def handle_call({:messages_for, agent_id}, _from, state) do
    messages =
      lookup_sorted(state.tab, agent_id)
      |> Enum.filter(&(&1.topic == "agent.message"))
      |> Enum.map(fn e -> %{role: e.data.role, content: e.data.content} end)

    {:reply, messages, state}
  end

  @impl true
  def handle_call({:events_for, agent_id}, _from, state) do
    {:reply, lookup_sorted(state.tab, agent_id), state}
  end

  @impl true
  def handle_call({:events_for, agent_id, since: iso_ts}, _from, state) do
    {:ok, dt, _} = DateTime.from_iso8601(iso_ts)

    events =
      lookup_sorted(state.tab, agent_id)
      |> Enum.filter(fn e ->
        case DateTime.from_iso8601(e.timestamp) do
          {:ok, t, _} -> DateTime.compare(t, dt) == :gt
          _ -> false
        end
      end)

    {:reply, events, state}
  end

  @impl true
  def handle_call({:clear, agent_id}, _from, state) do
    :dets.match_delete(state.tab, {agent_id, :_})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:clear_all, _from, state) do
    :dets.delete_all_objects(state.tab)
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    :dets.close(state.tab)
    :ok
  end

  ## Internal

  defp extract_agent_id(event) do
    case event.data do
      %{agent_id: id} -> id
      _ -> :system
    end
  end

  defp lookup_sorted(tab, agent_id) do
    :dets.lookup(tab, agent_id)
    |> Enum.map(fn {_key, event} -> event end)
    |> Enum.sort_by(& &1.timestamp)
  end
end

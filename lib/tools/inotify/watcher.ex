defmodule LLMAgent.Tools.Inotify.Watcher do
  @moduledoc """
  GenServer managing inotifywait ports and event buffers.

  Each watch opens a `inotifywait -m` port on a filesystem path,
  buffers incoming events, and lets callers poll or stop watches.
  """

  use GenServer

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Start watching a path. Returns `{:ok, watch_id}` or `{:error, reason}`.

  ## Examples

      {:ok, id} = LLMAgent.Tools.Inotify.Watcher.start_watch("/tmp")
      LLMAgent.Tools.Inotify.Watcher.stop_watch(id)

  Nonexistent path:

      iex> {:error, :path_not_found} = LLMAgent.Tools.Inotify.Watcher.start_watch("/no/such/path")
  """
  def start_watch(path, opts \\ %{}, server \\ __MODULE__) do
    GenServer.call(server, {:start_watch, path, opts})
  end

  @doc """
  Drain buffered events for a watch. Returns `{:ok, events}` and clears the buffer.

  ## Examples

      iex> {:error, :unknown_watch} = LLMAgent.Tools.Inotify.Watcher.poll(999_999)
  """
  def poll(watch_id, server \\ __MODULE__) do
    GenServer.call(server, {:poll, watch_id})
  end

  @doc """
  Stop a watch, close its port, and return final buffered events.

  ## Examples

      iex> {:error, :unknown_watch} = LLMAgent.Tools.Inotify.Watcher.stop_watch(999_999)
  """
  def stop_watch(watch_id, server \\ __MODULE__) do
    GenServer.call(server, {:stop_watch, watch_id})
  end

  @doc """
  List active watches as `[{watch_id, path}]`.

  ## Examples

      iex> {:ok, watches} = LLMAgent.Tools.Inotify.Watcher.list_watches()
      iex> is_list(watches)
      true
  """
  def list_watches(server \\ __MODULE__) do
    GenServer.call(server, :list_watches)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_) do
    {:ok, %{watches: %{}, next_id: 1}}
  end

  @impl true
  def handle_call({:start_watch, path, _opts}, _from, state) do
    case System.find_executable("inotifywait") do
      nil ->
        {:reply, {:error, :missing_binary}, state}

      bin ->
        if File.exists?(path) do
          id = state.next_id
          port = Port.open({:spawn_executable, bin}, [
            :binary,
            :exit_status,
            {:line, 4096},
            {:args, ["-m", "--format", "%e %w%f", path]}
          ])

          watch = %{port: port, path: path, events: []}
          watches = Map.put(state.watches, id, watch)

          LLMAgent.Events.emit(:watch_started, "tool.inotify", %{
            watch_id: id, path: path
          }, __MODULE__)

          {:reply, {:ok, id}, %{state | watches: watches, next_id: id + 1}}
        else
          {:reply, {:error, :path_not_found}, state}
        end
    end
  end

  def handle_call({:poll, watch_id}, _from, state) do
    case Map.fetch(state.watches, watch_id) do
      {:ok, watch} ->
        events = Enum.reverse(watch.events)
        watches = Map.put(state.watches, watch_id, %{watch | events: []})
        {:reply, {:ok, events}, %{state | watches: watches}}

      :error ->
        {:reply, {:error, :unknown_watch}, state}
    end
  end

  def handle_call({:stop_watch, watch_id}, _from, state) do
    case Map.pop(state.watches, watch_id) do
      {nil, _} ->
        {:reply, {:error, :unknown_watch}, state}

      {watch, watches} ->
        final_events = Enum.reverse(watch.events)
        # Send EOF to port to trigger inotifywait exit, then close
        try do
          Port.close(watch.port)
        rescue
          _ -> :ok
        end

        LLMAgent.Events.emit(:watch_stopped, "tool.inotify", %{
          watch_id: watch_id, path: watch.path, final_event_count: length(final_events)
        }, __MODULE__)

        {:reply, {:ok, final_events}, %{state | watches: watches}}
    end
  end

  def handle_call(:list_watches, _from, state) do
    list = Enum.map(state.watches, fn {id, w} -> {id, w.path} end)
    {:reply, {:ok, list}, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, state) do
    state = buffer_event(state, port, line)
    {:noreply, state}
  end

  def handle_info({port, {:data, {:noeol, line}}}, state) do
    # Partial line — treat same as full line for robustness
    state = buffer_event(state, port, line)
    {:noreply, state}
  end

  def handle_info({_port, {:exit_status, _status}}, state) do
    # Port exited (e.g. watched path deleted). Leave watch in map so
    # poll/stop can still drain buffered events.
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Internal ---

  defp buffer_event(state, port, line) do
    case find_watch_by_port(state.watches, port) do
      {id, watch} ->
        event = parse_event(line)

        LLMAgent.Events.emit(:fs_event, "tool.inotify.event", %{
          watch_id: id, event: event.event, path: event.path
        }, __MODULE__)

        updated = %{watch | events: [event | watch.events]}
        %{state | watches: Map.put(state.watches, id, updated)}

      nil ->
        state
    end
  end

  defp find_watch_by_port(watches, port) do
    Enum.find_value(watches, fn {id, w} ->
      if w.port == port, do: {id, w}
    end)
  end

  defp parse_event(line) do
    case String.split(line, " ", parts: 2) do
      [event_type, path] ->
        %{event: event_type, path: path, timestamp: DateTime.utc_now()}

      [event_type] ->
        %{event: event_type, path: "", timestamp: DateTime.utc_now()}
    end
  end
end

defmodule LLMAgent.Tools.Inotify.Watcher do
  use GenServer

  alias LLMAgent.Event
  alias LLMAgent.Events.EventStruct
  alias LLMAgent.EventLog
  alias LLMAgent.EventBus

  def start_link(path) do
    GenServer.start_link(__MODULE__, path, name: via(path))
  end

  def stop(path) do
    GenServer.stop(via(path))
  end

  defp via(path) do
    {:via, Registry, {LLMAgent.Registry, {:watcher, path}}}
  end

  @impl true
  def init(path) do
    Process.flag(:trap_exit, true)

    log_event(:start, path, "Started inotify watch")

    port = Port.open({:spawn_executable, "/usr/bin/inotifywait"}, [
      :binary,
      :exit_status,
      args: ["-m", "-q", "-e", "modify,create,delete", path]
    ])

    {:ok, %{path: path, port: port}}
  end

  @impl true
  def handle_info({port, {:data, raw}}, state = %{port: port, path: path}) do
    message = String.trim(raw)

    event = Event.to_event(%{
      type: :message,
      topic: "fs:#{path}",
      data: message,
      source: __MODULE__
    })

    EventLog.record(event)
    EventBus.broadcast(event.topic, event)

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{path: path}) do
    log_event(:stop, path, "Stopped inotify watch")
    :ok
  end

  defp log_event(type, path, data) do
    EventStruct.new(type, "fs:#{path}", data, __MODULE__)
    |> EventLog.record()
  end
end

defmodule LLMAgent.Tools.Inotify do
  @moduledoc """
  Monitors filesystem events using inotify.

  Supported actions:
    - "watch": Start watching a path for filesystem events
    - "poll": Drain buffered events for a watch
    - "stop": Stop watching and return final events
    - "list": List active watches

  Requires `inotifywait` binary (from inotify-tools package).
  """

  @behaviour LLMAgent.Tool
  alias Comn.Errors.ErrorStruct
  alias LLMAgent.Tools.Inotify.Watcher

  @doc """
  Returns a human-readable description of the Inotify tool.

  ## Examples

      iex> LLMAgent.Tools.Inotify.describe()
      "Watches files or directories for changes via inotify. Actions: watch, poll, stop, list."
  """
  @impl true
  def describe do
    "Watches files or directories for changes via inotify. Actions: watch, poll, stop, list."
  end

  @doc ~S"""
  Perform an inotify action.

  ## Examples

      # Start watching a directory
      {:ok, %{output: watch_id, metadata: %{status: :watching}}} =
        LLMAgent.Tools.Inotify.perform("watch", %{"path" => "/tmp"})

      # Poll for events
      {:ok, %{output: events, metadata: %{count: _}}} =
        LLMAgent.Tools.Inotify.perform("poll", %{"watch_id" => watch_id})

      # List active watches
      {:ok, %{output: watches, metadata: %{count: _}}} =
        LLMAgent.Tools.Inotify.perform("list", %{})

      # Stop watching
      {:ok, %{output: final_events, metadata: %{status: :stopped}}} =
        LLMAgent.Tools.Inotify.perform("stop", %{"watch_id" => watch_id})

  Nonexistent path returns error:

      iex> {:error, %Comn.Errors.ErrorStruct{reason: "not_found"}} =
      ...>   LLMAgent.Tools.Inotify.perform("watch", %{"path" => "/no/such/path"})

  Unknown action returns error:

      iex> {:error, %Comn.Errors.ErrorStruct{reason: "unknown_command"}} =
      ...>   LLMAgent.Tools.Inotify.perform("nope", %{})
  """
  @impl true
  def perform("watch", %{"path" => path} = args) do
    opts = Map.get(args, "events", %{})

    case Watcher.start_watch(path, opts) do
      {:ok, watch_id} ->
        {:ok, %{output: watch_id, metadata: %{path: path, status: :watching}}}

      {:error, :missing_binary} ->
        {:error, ErrorStruct.new("missing_binary", "inotifywait",
          "inotifywait not found in PATH",
          "Install inotify-tools: apt install inotify-tools")}

      {:error, :path_not_found} ->
        {:error, ErrorStruct.new("not_found", "path", "Path does not exist: #{path}")}
    end
  end

  def perform("poll", %{"watch_id" => watch_id}) do
    case Watcher.poll(watch_id) do
      {:ok, events} ->
        {:ok, %{output: events, metadata: %{watch_id: watch_id, count: length(events)}}}

      {:error, :unknown_watch} ->
        {:error, ErrorStruct.new("not_found", "watch_id", "No active watch with id #{watch_id}")}
    end
  end

  def perform("stop", %{"watch_id" => watch_id}) do
    case Watcher.stop_watch(watch_id) do
      {:ok, final_events} ->
        {:ok, %{output: final_events, metadata: %{watch_id: watch_id, status: :stopped}}}

      {:error, :unknown_watch} ->
        {:error, ErrorStruct.new("not_found", "watch_id", "No active watch with id #{watch_id}")}
    end
  end

  def perform("list", _args) do
    {:ok, watches} = Watcher.list_watches()

    formatted = Enum.map(watches, fn {id, path} -> %{watch_id: id, path: path} end)
    {:ok, %{output: formatted, metadata: %{count: length(formatted)}}}
  end

  def perform(_, _),
    do: {:error, ErrorStruct.new("unknown_command", nil, "Unrecognized Inotify action")}
end

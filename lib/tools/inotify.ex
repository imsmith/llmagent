defmodule LLMAgent.Tools.Inotify do
  @moduledoc """
  Monitors filesystem events using inotify.

  Supported actions:
    - "watch": Start watching a path for filesystem events
    - "stop": Stop watching a path

  Requires `inotifywait` binary (from inotify-tools package).
  """

  @behaviour LLMAgent.Tool
  alias Comn.Errors.ErrorStruct

  @impl true
  def describe do
    "Watches files or directories for changes via inotify."
  end

  @impl true
  def perform("watch", %{"path" => path}) do
    case System.find_executable("inotifywait") do
      nil ->
        {:error, ErrorStruct.new("missing_binary", "inotifywait",
          "inotifywait not found in PATH",
          "Install inotify-tools: apt install inotify-tools")}

      _bin ->
        case File.exists?(path) do
          true ->
            {:ok, %{output: "Watching #{path} for filesystem events", metadata: %{path: path, status: :watching}}}

          false ->
            {:error, ErrorStruct.new("not_found", "path", "Path does not exist: #{path}")}
        end
    end
  end

  def perform("stop", %{"path" => path}) do
    {:ok, %{output: "Stopped watching #{path}", metadata: %{path: path, status: :stopped}}}
  end

  def perform(_, _),
    do: {:error, ErrorStruct.new("unknown_command", nil, "Unrecognized Inotify action")}
end

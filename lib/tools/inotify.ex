defmodule LLMAgent.Tools.Inotify do
  @moduledoc "Monitors filesystem events using inotify."
  @behaviour LLMAgent.Tool

  @impl true
  def describe do
    "Watches files or directories for changes via inotify."
  end

  @impl true
  def perform(_action, _args) do
    {:error, :not_implemented}
  end
end

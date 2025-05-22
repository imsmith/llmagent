defmodule LLMAgent.Tools.Systemd do
  @moduledoc "Interacts with systemd to manage Linux services."
  @behaviour LLMAgent.Tool

  @impl true
  def describe do
    "Starts, stops, and queries systemd services."
  end

  @impl true
  def perform(_action, _args) do
    {:error, :not_implemented}
  end
end

defmodule LLMAgent.Tools.DBus do
  @moduledoc "Provides access to Linux D-Bus messaging system."
  @behaviour LLMAgent.Tool

  @impl true
  def describe do
    "Sends and receives messages over D-Bus."
  end

  @impl true
  def perform(_action, _args) do
    {:error, :not_implemented}
  end
end

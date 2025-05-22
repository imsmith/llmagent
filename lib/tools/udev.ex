defmodule LLMAgent.Tools.Udev do
  @moduledoc "Interacts with Linux udev for device management."
  @behaviour LLMAgent.Tool

  @impl true
  def describe do
    "Lists and queries connected devices via udev."
  end

  @impl true
  def perform(_action, _args) do
    {:error, :not_implemented}
  end
end

defmodule LLMAgent.Tools.Bash do
  @moduledoc "Provides interaction with the Linux Bash shell."
  @behaviour LLMAgent.Tool

  @impl true
  def describe do
    "Executes shell commands via Bash."
  end

  @impl true
  def perform("exec", %{"command" => cmd}) when is_binary(cmd) do
    {output, 0} = System.cmd("bash", ["-c", cmd], stderr_to_stdout: true)
    output
  end

  def perform(_, _), do: {:error, :unknown_command}
end

defmodule LLMAgent.Tools.Bash do
  @moduledoc """
  Provides interaction with the Linux Bash shell.

  ### Supported actions:
    - `"exec"`: Executes a Bash shell command

  ### Input:
    - `"command"`: Bash-compatible command string

  ### Response:
    - `{:ok, %{output: string, metadata: %{exit_code: integer}}}`
    - `{:error, %Comn.Errors.ErrorStruct{}}`
  """

  @behaviour LLMAgent.Tool
  alias Comn.Errors.ErrorStruct

  @impl true
  def describe do
    """
    Executes Linux Bash commands using `bash -c`.

    Action:
      - `exec`: runs a shell command string

    Required input:
      - `command`: string to execute

    Response:
      - On success: `{:ok, %{output: ..., metadata: %{exit_code: 0}}}`
      - On failure: `{:error, %ErrorStruct{}}`
    """
  end

  @impl true
  def perform("exec", %{"command" => cmd}) when is_binary(cmd) do
    try do
      {output, exit_code} = System.cmd("bash", ["-c", cmd], stderr_to_stdout: true)

      if exit_code == 0 do
        {:ok, %{output: output, metadata: %{exit_code: exit_code}}}
      else
        {:error,
         ErrorStruct.new(
           "command_failed",
           "command",
           "Bash exited with status #{exit_code}",
           "Check syntax, permissions, or environment."
         )}
      end
    rescue
      e in ErlangError ->
        {:error,
         ErrorStruct.new(
           "execution_error",
           "command",
           Exception.message(e),
           "Bash could not be started"
         )}
    end
  end

  def perform(_, _),
    do: {:error, ErrorStruct.new("unknown_command", nil, "Unrecognized Bash action")}
end

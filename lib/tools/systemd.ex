defmodule LLMAgent.Tools.Systemd do
  @moduledoc """
  Interacts with systemd to manage Linux services.

  Supported actions:
  - `"status"`: gets the status of a service
  - `"start"`: starts a service
  - `"stop"`: stops a service
  - `"restart"`: restarts a service
  - `"list"`: lists all running services
  """

  @behaviour LLMAgent.Tool

  @impl true
  def describe do
    """
    Starts, stops, and queries systemd services.

    Actions:
      - status: get status of a service (requires "unit")
      - start: start a service (requires "unit")
      - stop: stop a service (requires "unit")
      - restart: restart a service (requires "unit")
      - list: list running services
    """
  end

  @impl true
  def perform("status", %{"unit" => unit}) do
    System.cmd("systemctl", ["status", unit], stderr_to_stdout: true)
    |> normalize()
  end

  def perform("start", %{"unit" => unit}) do
    System.cmd("systemctl", ["start", unit], stderr_to_stdout: true)
    |> normalize()
  end

  def perform("stop", %{"unit" => unit}) do
    System.cmd("systemctl", ["stop", unit], stderr_to_stdout: true)
    |> normalize()
  end

  def perform("restart", %{"unit" => unit}) do
    System.cmd("systemctl", ["restart", unit], stderr_to_stdout: true)
    |> normalize()
  end

  def perform("list", _args) do
    System.cmd("systemctl", ["list-units", "--type=service", "--state=running"], stderr_to_stdout: true)
    |> normalize()
  end

  def perform(_, _), do: {:error, :unknown_command}

  defp normalize({out, 0}), do: {:ok, String.trim(out)}
  defp normalize({out, _}), do: {:error, String.trim(out)}
end

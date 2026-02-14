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
  alias Comn.Errors.ErrorStruct

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
  def perform("status", %{"unit" => unit}), do: run_systemctl(["status", unit], %{unit: unit})
  def perform("start", %{"unit" => unit}), do: run_systemctl(["start", unit], %{unit: unit})
  def perform("stop", %{"unit" => unit}), do: run_systemctl(["stop", unit], %{unit: unit})
  def perform("restart", %{"unit" => unit}), do: run_systemctl(["restart", unit], %{unit: unit})

  def perform("list", _args) do
    run_systemctl(["list-units", "--type=service", "--state=running"], %{action: "list"})
  end

  def perform(_, _),
    do: {:error, ErrorStruct.new("unknown_command", nil, "Unrecognized Systemd action")}

  defp run_systemctl(args, metadata) do
    case System.cmd("systemctl", args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, %{output: String.trim(out), metadata: metadata}}
      {out, _} -> {:ok, %{output: String.trim(out), metadata: Map.put(metadata, :degraded, true)}}
    end
  end
end

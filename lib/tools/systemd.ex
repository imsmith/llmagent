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
  @behaviour LLMAgent.Tool.Kinds.Query
  @behaviour LLMAgent.Tool.Kinds.Action
  alias Comn.Errors.ErrorStruct

  @doc """
  Returns a human-readable description of the Systemd tool.

  ## Examples

      iex> LLMAgent.Tools.Systemd.describe()
      ...> |> is_binary()
      true
  """
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

  @doc "Authoritative tool ad."
  @impl LLMAgent.Tool
  @spec ad() :: LLMAgent.ToolAd.t()
  def ad do
    LLMAgent.ToolAd.new(%{
      id: "builtin.systemd",
      coordinate: "function.systemd",
      kinds: [:query, :action],
      binding: {:module, __MODULE__},
      operational: %{
        actions: %{
          "status"  => %{inputs: %{}, outputs: %{}, pre: nil, post: nil},
          "list"    => %{inputs: %{}, outputs: %{}, pre: nil, post: nil},
          "start"   => %{inputs: %{}, outputs: %{}, pre: nil, post: nil},
          "stop"    => %{inputs: %{}, outputs: %{}, pre: nil, post: nil},
          "restart" => %{inputs: %{}, outputs: %{}, pre: nil, post: nil}
        }
      },
      constraint: %{
        idempotency: %{
          "status"  => :idempotent,
          "list"    => :idempotent,
          "start"   => :non_idempotent,
          "stop"    => :non_idempotent,
          "restart" => :non_idempotent
        },
        blast_radius: %{
          "status"  => :local,
          "list"    => :local,
          "start"   => :system,
          "stop"    => :system,
          "restart" => :system
        }
      },
      affordance: %{
        declared: [%{
          intent: "inspect and control systemd units",
          suits: "service management on Linux hosts",
          avoid_when: "the target host doesn't run systemd"
        }],
        learned: [],
        open: false
      },
      fidelity: :authoritative,
      provenance: %{source: "llmagent.builtin", produced_at: ~U[2026-05-18 00:00:00Z], based_on: [], signature: nil},
      lease: :permanent,
      meta: %{}
    })
  end

  @impl LLMAgent.Tool.Kinds.Query
  def query(action, args) when action in ["status", "list"] do
    case perform(action, args) do
      {:ok, %{output: out, metadata: meta}} -> {:ok, out, meta}
      {:error, _} = err -> err
    end
  end

  def query(_, _), do: {:error, :unknown_action}

  @impl LLMAgent.Tool.Kinds.Action
  def act(action, args, _idempotency_key) when action in ["start", "stop", "restart"] do
    case perform(action, args) do
      {:ok, %{output: out, metadata: meta}} -> {:ok, out, meta}
      {:error, _} = err -> err
    end
  end

  def act(_, _, _), do: {:error, :unknown_action}

  @doc ~S"""
  Perform a systemd action.

  ## Examples

      # Get status of a unit (returns parsed key-value properties)
      {:ok, %{output: props, metadata: %{unit: "sshd", active: _}}} =
        LLMAgent.Tools.Systemd.perform("status", %{"unit" => "sshd"})
      # props is a map like %{"activestate" => "active", "loadstate" => "loaded", ...}

      # List running services (returns list of service maps)
      {:ok, %{output: services, metadata: %{action: "list", count: _}}} =
        LLMAgent.Tools.Systemd.perform("list", %{})

  Unknown action returns error:

      iex> {:error, %Comn.Errors.ErrorStruct{reason: "unknown_command"}} =
      ...>   LLMAgent.Tools.Systemd.perform("nope", %{})
  """
  @impl true
  def perform("status", %{"unit" => unit}) do
    case System.cmd("systemctl", ["show", unit, "--no-pager"], stderr_to_stdout: true) do
      {out, 0} ->
        props = parse_systemctl_show(out)
        active = Map.get(props, "activestate") in ["active", "activating"]
        {:ok, %{output: props, metadata: %{unit: unit, active: active}}}

      {out, code} ->
        {:error, ErrorStruct.new("command_failed", "unit", "systemctl show failed (exit #{code}): #{String.trim(out)}")}
    end
  end

  def perform("start", %{"unit" => unit}), do: run_systemctl(["start", unit], %{unit: unit, action: "start"})
  def perform("stop", %{"unit" => unit}), do: run_systemctl(["stop", unit], %{unit: unit, action: "stop"})
  def perform("restart", %{"unit" => unit}), do: run_systemctl(["restart", unit], %{unit: unit, action: "restart"})

  def perform("list", _args) do
    case System.cmd("systemctl", ["list-units", "--type=service", "--state=running", "--no-pager", "--plain", "--no-legend"], stderr_to_stdout: true) do
      {out, 0} ->
        services = parse_list_units(out)
        {:ok, %{output: services, metadata: %{action: "list", count: length(services)}}}

      {out, code} ->
        {:error, ErrorStruct.new("command_failed", "systemctl", "systemctl list-units failed (exit #{code}): #{String.trim(out)}")}
    end
  end

  def perform(_, _),
    do: {:error, ErrorStruct.new("unknown_command", nil, "Unrecognized Systemd action")}

  defp run_systemctl(args, metadata) do
    case System.cmd("systemctl", args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, %{output: String.trim(out), metadata: metadata}}
      {out, code} -> {:error, ErrorStruct.new("command_failed", "systemctl", "systemctl failed (exit #{code}): #{String.trim(out)}")}
    end
  end

  defp parse_systemctl_show(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "=", parts: 2) do
        [key, val] -> Map.put(acc, String.downcase(String.trim(key)), String.trim(val))
        _ -> acc
      end
    end)
  end

  defp parse_list_units(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      parts = String.split(line, ~r/\s+/, trim: true)
      case parts do
        [unit, load, active, sub | desc] ->
          %{unit: unit, load: load, active: active, sub: sub, description: Enum.join(desc, " ")}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
end

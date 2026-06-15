defmodule LLMAgent.Tools.Proc do
  @moduledoc "Provides structured introspection of running processes and /proc system data."
  @behaviour LLMAgent.Tool
  @behaviour LLMAgent.Tool.Kinds.Query
  alias Comn.Errors.ErrorStruct

  @doc """
  Returns a human-readable description of the Proc tool.

  ## Examples

      iex> LLMAgent.Tools.Proc.describe()
      "Accesses process lists and details via /proc."
  """
  @impl true
  def describe do
    "Accesses process lists and details via /proc."
  end

  @doc ~S"""
  Perform a process inspection action.

  ## Examples

      # List running processes
      {:ok, %{output: procs, metadata: %{count: n}}} =
        LLMAgent.Tools.Proc.perform("list", %{})

      # Get info for PID 1 (returns parsed key-value map)
      {:ok, %{output: info, metadata: %{pid: 1}}} =
        LLMAgent.Tools.Proc.perform("info", %{"pid" => 1})
      # info is a map like %{"name" => "systemd", "state" => "S (sleeping)", ...}

  Unknown action returns error:

      iex> {:error, %Comn.Errors.ErrorStruct{reason: "unknown_command"}} =
      ...>   LLMAgent.Tools.Proc.perform("nope", %{})
  """
  @impl true
  def perform("list", _args) do
    case System.cmd("ps", ["-eo", "pid,comm,%cpu,%mem", "--no-headers"], stderr_to_stdout: true) do
      {out, 0} ->
        lines = String.split(out, "\n", trim: true)

        result =
          Enum.map(lines, fn line ->
            parts = String.split(line, ~r/\s+/, trim: true)

            case parts do
              [pid, cmd | rest] ->
                {cpu, mem} =
                  case rest do
                    [c, m] -> {parse_float(c), parse_float(m)}
                    _ -> {0.0, 0.0}
                  end

                %{pid: String.to_integer(pid), cmd: cmd, cpu: cpu, mem: mem}

              _ ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, %{output: result, metadata: %{count: length(result)}}}

      {err, code} ->
        {:error, ErrorStruct.new("command_failed", "ps", "ps failed (exit #{code}): #{String.trim(err)}")}
    end
  end

  def perform("info", %{"pid" => pid}) when is_integer(pid) do
    path = "/proc/#{pid}/status"

    with true <- File.exists?(path),
         {:ok, contents} <- File.read(path) do
      parsed = parse_proc_status(contents)
      {:ok, %{output: parsed, metadata: %{pid: pid, path: path}}}
    else
      false ->
        {:error, ErrorStruct.new("not_found", "pid", "Process #{pid} not found")}

      {:error, reason} ->
        {:error, ErrorStruct.new("file_error", "pid", "Cannot read #{path}: #{reason}")}
    end
  end

  def perform(_, _),
    do: {:error, ErrorStruct.new("unknown_command", nil, "Unrecognized Proc action")}

  @doc "Authoritative tool ad."
  @impl LLMAgent.Tool
  @spec ad() :: LLMAgent.ToolAd.t()
  def ad do
    actions = ~w(list info)

    LLMAgent.ToolAd.new(%{
      id: "builtin.proc",
      coordinate: "resource.proc",
      kinds: [:query],
      binding: {:module, __MODULE__},
      operational: %{
        actions: Map.new(actions, &{&1, %{inputs: %{}, outputs: %{}, pre: nil, post: nil}})
      },
      constraint: %{
        idempotency: Map.new(actions, &{&1, :idempotent}),
        blast_radius: Map.new(actions, &{&1, :local})
      },
      affordance: %{
        declared: [
          %{intent: "inspect running processes via /proc", suits: "diagnostic queries", avoid_when: nil}
        ],
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
  def query(action, args) do
    case perform(action, args) do
      {:ok, %{output: out, metadata: meta}} -> {:ok, out, meta}
      {:error, _} = err -> err
    end
  end

  defp parse_proc_status(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":\t", parts: 2) do
        [key, val] -> Map.put(acc, String.downcase(String.trim(key)), String.trim(val))
        _ -> acc
      end
    end)
  end

  defp parse_float(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0.0
    end
  end
end

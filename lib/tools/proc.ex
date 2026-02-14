defmodule LLMAgent.Tools.Proc do
  @moduledoc "Provides structured introspection of running processes and /proc system data."
  @behaviour LLMAgent.Tool
  alias Comn.Errors.ErrorStruct

  @impl true
  def describe do
    "Accesses process lists and details via /proc."
  end

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
      {:ok, %{output: contents, metadata: %{pid: pid}}}
    else
      false ->
        {:error, ErrorStruct.new("not_found", "pid", "Process #{pid} not found")}

      {:error, reason} ->
        {:error, ErrorStruct.new("file_error", "pid", "Cannot read #{path}: #{reason}")}
    end
  end

  def perform(_, _),
    do: {:error, ErrorStruct.new("unknown_command", nil, "Unrecognized Proc action")}

  defp parse_float(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0.0
    end
  end
end

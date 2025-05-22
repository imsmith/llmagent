defmodule LLMAgent.Tools.Proc do
  @moduledoc "Provides structured introspection of running processes and /proc system data."
  @behaviour LLMAgent.Tool

  @impl true
  def describe do
    "Accesses process lists and details via /proc."
  end

  @impl true
  def perform("list", _args) do
    System.cmd("ps", ["-eo", "pid,comm,%cpu,%mem", "--no-headers"], stderr_to_stdout: true)
    |> case do
      {out, 0} ->
        lines = String.split(out, "\n", trim: true)

        result =
          Enum.map(lines, fn line ->
            [pid, cmd, cpu, mem] = String.split(line, ~r/\s+/, trim: true)
            %{
              pid: String.to_integer(pid),
              cmd: cmd,
              cpu: String.to_float(cpu),
              mem: String.to_float(mem)
            }
          end)

        {:ok, result}

      {err, _} -> {:error, err}
    end
  end

  def perform("info", %{"pid" => pid}) when is_integer(pid) do
    with true <- File.exists?("/proc/#{pid}/status"),
         {:ok, contents} <- File.read("/proc/#{pid}/status") do
      {:ok, contents}
    else
      _ -> {:error, :not_found}
    end
  end

  def perform(_, _), do: {:error, :unknown_command}
end

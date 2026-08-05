defmodule LLMAgent.OSProcess do
  @moduledoc """
  Signalling for OS processes spawned as Erlang ports.

  `Port.close/1` closes the pipes; it does not signal the program. A child that
  does not exit on stdin EOF therefore survives its owner, keeps running, and
  keeps holding the stdout it inherited — which hangs whatever is reading that
  pipe. Both `LLMAgent.Discovery.PortAdapter` and `LLMAgent.Tool.Adapter.Exec`
  need the same escalating kill, so it lives here once.
  """

  @default_grace_ms 200

  @doc "True when the process exists and is not a zombie."
  @spec alive?(non_neg_integer()) :: boolean()
  def alive?(os_pid) when is_integer(os_pid) do
    case File.read("/proc/#{os_pid}/stat") do
      {:ok, stat} ->
        state = stat |> String.split(") ") |> List.last() |> String.first()
        state != "Z"

      {:error, _} ->
        false
    end
  end

  @doc """
  Terminate a process: SIGTERM, a grace period, then SIGKILL if it is still up.

  Accepts `nil` so callers need not special-case a port that never opened.
  """
  @spec reap(non_neg_integer() | nil, non_neg_integer()) :: :ok
  def reap(os_pid, grace_ms \\ @default_grace_ms)

  def reap(nil, _grace_ms), do: :ok

  def reap(os_pid, grace_ms) when is_integer(os_pid) do
    signal(os_pid, "-TERM")
    Process.sleep(grace_ms)

    if alive?(os_pid) do
      signal(os_pid, "-KILL")
    end

    :ok
  end

  defp signal(os_pid, sig) do
    System.cmd("kill", [sig, Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    # `kill` missing from PATH is not worth taking a shutdown down for.
    ErlangError -> :ok
  end
end

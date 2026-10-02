defmodule LLMAgent.OSProcessTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias LLMAgent.OSProcess

  # A killed child stays in /proc as a zombie until reaped, so existence alone
  # is not liveness — read the state field out of stat.
  defp spawn_sleeper do
    port =
      Port.open(
        {:spawn_executable, System.find_executable("sleep")},
        [:binary, :exit_status, {:args, ["300"]}]
      )

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {port, os_pid}
  end

  # Port becomes invalid when the OS process is killed, so check before closing.
  defp close_port(port) do
    if is_port(port) and Port.info(port) != nil do
      Port.close(port)
    end
  end

  test "alive?/1 is true for a running process" do
    {port, os_pid} = spawn_sleeper()
    assert OSProcess.alive?(os_pid)
    OSProcess.reap(os_pid)
    close_port(port)
  end

  test "alive?/1 is false for a pid that does not exist" do
    refute OSProcess.alive?(2_147_483_646)
  end

  test "reap/1 kills a running process" do
    {port, os_pid} = spawn_sleeper()
    assert :ok = OSProcess.reap(os_pid)
    refute OSProcess.alive?(os_pid)
    close_port(port)
  end

  test "reap/1 accepts nil" do
    assert :ok = OSProcess.reap(nil)
  end

  test "reap/1 is safe to call twice" do
    {port, os_pid} = spawn_sleeper()
    assert :ok = OSProcess.reap(os_pid)
    assert :ok = OSProcess.reap(os_pid)
    close_port(port)
  end

  # perl is the parent that makes a stable zombie possible: it forks and never
  # waits. Alpine's base image has no perl, so the test is defined only where
  # it can actually run.
  if System.find_executable("perl") do
    test "alive?/1 is false for a zombie process" do
      # Perl forks and never waits, leaving the child as a stable zombie.
      perl_path = System.find_executable("perl")
      cmd = perl_path

      args = [
        "-e",
        "my $pid = fork(); if (!defined $pid) { die } if ($pid == 0) { exit 0 } sleep 6;"
      ]

      port =
        Port.open(
          {:spawn_executable, cmd},
          [:binary, :exit_status, {:args, args}]
        )

      {:os_pid, parent_pid} = Port.info(port, :os_pid)

      # Find the zombie child by polling the parent's children list.
      # The child exits quickly but the parent never waits, so it becomes a stable zombie.
      zombie_pid = find_zombie_child(parent_pid, 500)
      assert is_integer(zombie_pid), "could not find zombie child of perl parent #{parent_pid}"

      # The zombie should NOT be alive, even though it exists as a pid.
      # This is the key assertion: kill -0 would return true; /proc stat returns false.
      refute OSProcess.alive?(zombie_pid),
             "zombie pid #{zombie_pid} must not be alive; this is the whole test"

      # Clean up: kill the perl parent.
      OSProcess.reap(parent_pid)
      close_port(port)
    end
  end

  defp find_zombie_child(parent_pid, timeout_ms) do
    # Poll the parent's children list for a zombie child.
    # Retry for a short bounded time since the child takes a moment to exit.
    find_zombie_child_retry(parent_pid, timeout_ms)
  end

  defp find_zombie_child_retry(_parent_pid, remaining_ms) when remaining_ms <= 0 do
    nil
  end

  defp find_zombie_child_retry(parent_pid, remaining_ms) do
    children_file = "/proc/#{parent_pid}/task/#{parent_pid}/children"

    case read_children(children_file) do
      {:ok, pids} ->
        Enum.find(pids, &is_zombie_state?/1) ||
          (Process.sleep(10) && find_zombie_child_retry(parent_pid, remaining_ms - 10))

      {:error, _} ->
        nil
    end
  end

  defp read_children(children_file) do
    with {:ok, content} <- File.read(children_file) do
      pids =
        content
        |> String.trim()
        |> String.split(" ")
        |> Enum.filter(&(&1 != ""))
        |> Enum.map(&String.to_integer/1)

      {:ok, pids}
    end
  end

  defp is_zombie_state?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        state = stat |> String.split(") ") |> List.last() |> String.first()
        state == "Z"

      {:error, _} ->
        false
    end
  end
end

defmodule LLMAgent.OSProcessTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias LLMAgent.OSProcess

  # A killed child stays in /proc as a zombie until reaped, so existence alone
  # is not liveness — read the state field out of stat.
  defp spawn_sleeper do
    port = Port.open({:spawn_executable, System.find_executable("sleep")},
                     [:binary, :exit_status, {:args, ["300"]}])
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
end

defmodule LLMAgent.Discovery.AdapterSupervisorTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias LLMAgent.Discovery.AdapterSupervisor

  test "supervisor is running and accepts children" do
    assert Process.whereis(AdapterSupervisor) |> is_pid()
    children = DynamicSupervisor.which_children(AdapterSupervisor)
    assert is_list(children)
  end

  test "start_adapter/1 launches a PortAdapter as a child" do
    spec = %{
      name: :sup_test_adapter,
      command: System.find_executable("true") || "/bin/true",
      args: [],
      env: []
    }

    {:ok, pid} = AdapterSupervisor.start_adapter(spec)
    assert Process.alive?(pid)
    DynamicSupervisor.terminate_child(AdapterSupervisor, pid)
  end
end

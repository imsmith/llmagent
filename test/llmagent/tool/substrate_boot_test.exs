defmodule LLMAgent.Tool.SubstrateBootTest do
  @moduledoc """
  Integration tests for tool-discovery substrate boot sequence.

  Verifies that Discovery, Kinds registry, and Bindings registry are properly
  initialized and running under the application supervisor.
  """

  use ExUnit.Case, async: false

  test "Discovery is running under the application supervisor" do
    pid = Process.whereis(LLMAgent.Tools.Discovery)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "Kinds registry is seeded after boot" do
    assert :compute in LLMAgent.Tool.Kinds.list_kinds()
    assert :action in LLMAgent.Tool.Kinds.list_kinds()
  end

  test "Bindings registry has the :module adapter after boot" do
    assert {:ok, LLMAgent.Tool.Adapter.Module} =
             LLMAgent.Tool.Bindings.adapter_for(:module)
  end

  test "umbrella LLMAgent.Tool behaviour declares ad/0" do
    callbacks = LLMAgent.Tool.behaviour_info(:callbacks)
    assert {:ad, 0} in callbacks
  end

  test "describe/0 and perform/2 are optional callbacks" do
    optional = LLMAgent.Tool.behaviour_info(:optional_callbacks)
    assert {:describe, 0} in optional
    assert {:perform, 2} in optional
  end
end

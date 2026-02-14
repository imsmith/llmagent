defmodule LLMAgent.Tools.ProcTest do
  use ExUnit.Case, async: true

  alias LLMAgent.Tools.Proc
  alias Comn.Errors.ErrorStruct

  describe "describe/0" do
    test "returns a string summary" do
      assert is_binary(Proc.describe())
    end
  end

  describe "perform/2" do
    test "returns error for unknown command" do
      {:error, %ErrorStruct{reason: "unknown_command"}} = Proc.perform("not_real", %{})
    end

    @tag :integration
    test "successfully performs list" do
      {:ok, %{output: procs, metadata: %{count: count}}} = Proc.perform("list", %{})

      assert is_list(procs)
      assert count > 0
    end
  end
end

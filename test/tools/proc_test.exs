defmodule LLMAgent.Tools.ProcTest do
  use ExUnit.Case, async: true

  alias LLMAgent.Tools.Proc

  describe "describe/0" do
    test "returns a string summary" do
      assert is_binary(Proc.describe())
    end
  end

  describe "perform/2" do
    test "returns error for unknown command" do
      assert {:error, :unknown_command} == Proc.perform("not_real", %{})
    end

    @tag :integration
    test "successfully performs list" do
      result = Proc.perform("list", %{})
      assert match?({:ok, list} when is_list(list), result)
    end
  end
end

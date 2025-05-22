defmodule LLMAgent.Tools.BashTest do
  use ExUnit.Case, async: true

  alias LLMAgent.Tools.Bash

  describe "describe/0" do
    test "returns a string summary" do
      assert is_binary(Bash.describe())
    end
  end

  describe "perform/2" do
    test "returns error for unknown command" do
      assert {:error, :unknown_command} == Bash.perform("not_real", %{})
    end

    @tag :integration
    test "successfully performs exec" do
      result = Bash.perform("exec", %{"command" => "echo hello"})
      assert match?({_out, 0}, result)
    end
  end
end

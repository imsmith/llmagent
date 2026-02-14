defmodule LLMAgent.Tools.BashTest do
  use ExUnit.Case, async: true

  alias LLMAgent.Tools.Bash
  alias Comn.Errors.ErrorStruct

  describe "perform/2 with \"exec\"" do
    test "runs a valid command and returns output" do
      {:ok, %{output: output, metadata: %{exit_code: 0}}} =
        Bash.perform("exec", %{"command" => "echo hello"})

      assert output =~ "hello"
    end

    test "returns error for failing command" do
      {:error, %ErrorStruct{} = err} =
        Bash.perform("exec", %{"command" => "exit 42"})

      assert err.reason == "command_failed"
      assert err.field == "command"
      assert err.message =~ "status 42"
    end

    test "returns error for missing command input" do
      result = Bash.perform("exec", %{})
      assert match?({:error, %ErrorStruct{}}, result)
    end

    test "returns error if input is not a string" do
      result = Bash.perform("exec", %{"command" => 123})
      assert match?({:error, _}, result)
    end
  end

  describe "perform/2 with unknown action" do
    test "returns error struct for unsupported action" do
      {:error, %ErrorStruct{} = err} = Bash.perform("explode", %{"command" => "ls"})

      assert err.reason == "unknown_command"
    end
  end
end

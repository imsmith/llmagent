defmodule LLMAgent.Tools.FileTest do
  use ExUnit.Case, async: true

  alias LLMAgent.Tools.File

  describe "describe/0" do
    test "returns a string summary" do
      assert is_binary(File.describe())
    end
  end

  describe "perform/2" do
    test "returns error for unknown command" do
      assert {:error, :unknown_command} == File.perform("not_real", %{})
    end

    @tag :integration
    test "successfully performs read" do
      result = File.perform("read", %{"path" => "/etc/hosts"})
      assert match?({:ok, _}, result)
    end
  end
end

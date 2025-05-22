defmodule LLMAgent.Tools.NetTest do
  use ExUnit.Case, async: true

  alias LLMAgent.Tools.Net

  describe "describe/0" do
    test "returns a string summary" do
      assert is_binary(Net.describe())
    end
  end

  describe "perform/2" do
    test "returns error for unknown command" do
      assert {:error, :unknown_command} == Net.perform("not_real", %{})
    end

    @tag :integration
    test "successfully performs resolve" do
      result = Net.perform("resolve", %{"host" => "example.com"})
      assert match?({_out, 0}, result)
    end
  end
end

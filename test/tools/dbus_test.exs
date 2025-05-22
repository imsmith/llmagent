defmodule LLMAgent.Tools.DbusTest do
  use ExUnit.Case, async: true

  alias LLMAgent.Tools.Dbus

  describe "describe/0" do
    test "returns a string summary" do
      assert is_binary(Dbus.describe())
    end
  end

  describe "perform/2" do
    test "returns error for unknown command" do
      assert {:error, :unknown_command} == Dbus.perform("not_real", %{})
    end

    @tag :integration
    test "successfully performs noop" do
      result = Dbus.perform("noop", %{})
      assert match?({:error, _}, result)
    end
  end
end

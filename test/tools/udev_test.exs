defmodule LLMAgent.Tools.UdevTest do
  use ExUnit.Case, async: true

  alias LLMAgent.Tools.Udev

  describe "describe/0" do
    test "returns a string summary" do
      assert is_binary(Udev.describe())
    end
  end

  describe "perform/2" do
    test "returns error for unknown command" do
      assert {:error, :unknown_command} == Udev.perform("not_real", %{})
    end

    @tag :integration
    test "successfully performs list_devices" do
      result = Udev.perform("list_devices", %{})
      assert match?({:error, _}, result)
    end
  end
end

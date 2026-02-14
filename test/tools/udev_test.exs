defmodule LLMAgent.Tools.UdevTest do
  use ExUnit.Case, async: true

  alias LLMAgent.Tools.Udev
  alias Comn.Errors.ErrorStruct

  describe "describe/0" do
    test "returns a string summary" do
      assert is_binary(Udev.describe())
    end
  end

  describe "perform/2" do
    test "returns error for unknown command" do
      {:error, %ErrorStruct{reason: "unknown_command"}} = Udev.perform("not_real", %{})
    end

    @tag :integration
    test "lists devices" do
      {:ok, %{output: %{block_devices: blk, usb_devices: usb}, metadata: _}} =
        Udev.perform("list", %{})

      assert is_binary(blk)
      assert is_binary(usb)
    end
  end
end

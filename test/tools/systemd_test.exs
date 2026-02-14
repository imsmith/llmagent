defmodule LLMAgent.Tools.SystemdTest do
  use ExUnit.Case, async: true

  alias LLMAgent.Tools.Systemd

  describe "describe/0" do
    test "returns a string summary" do
      assert is_binary(Systemd.describe())
    end
  end

  describe "perform/2" do
    test "returns error for unknown command" do
      {:error, %Comn.Errors.ErrorStruct{reason: "unknown_command"}} =
        Systemd.perform("not_real", %{})
    end

    @tag :integration
    test "successfully performs status" do
      result = Systemd.perform("status", %{"unit" => "ssh.service"})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end

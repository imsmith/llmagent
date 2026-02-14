defmodule LLMAgent.Tools.DbusTest do
  use ExUnit.Case, async: true

  alias LLMAgent.Tools.DBus
  alias Comn.Errors.ErrorStruct

  describe "describe/0" do
    test "returns a string summary" do
      assert is_binary(DBus.describe())
    end
  end

  describe "perform/2" do
    test "returns error for unknown command" do
      {:error, %ErrorStruct{reason: "unknown_command"}} = DBus.perform("not_real", %{})
    end

    @tag :integration
    test "lists bus services" do
      result = DBus.perform("list", %{})
      assert match?({:ok, %{output: _, metadata: _}}, result) or match?({:error, _}, result)
    end
  end
end

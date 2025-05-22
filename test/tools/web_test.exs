defmodule LLMAgent.Tools.WebTest do
  use ExUnit.Case, async: true

  alias LLMAgent.Tools.Web

  describe "describe/0" do
    test "returns a string summary" do
      assert is_binary(Web.describe())
    end
  end

  describe "perform/2" do
    test "returns error for unknown command" do
      assert {:error, :unknown_command} == Web.perform("not_real", %{})
    end

    @tag :integration
    test "successfully performs get" do
      result = Web.perform("get", %{"url" => "https://httpbin.org/get"})
      assert match?({:ok, %Req.Response{}}, result)
    end
  end
end

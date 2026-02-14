defmodule LLMAgent.Tools.NetTest do
  use ExUnit.Case, async: true

  alias LLMAgent.Tools.Net
  alias Comn.Errors.ErrorStruct

  describe "describe/0" do
    test "returns a string summary" do
      assert is_binary(Net.describe())
    end
  end

  describe "perform/2" do
    test "returns error for unknown command" do
      {:error, %ErrorStruct{reason: "unknown_command"}} = Net.perform("not_real", %{})
    end

    @tag :integration
    test "resolves a hostname" do
      {:ok, %{output: addrs, metadata: %{host: "example.com"}}} =
        Net.perform("resolve", %{"host" => "example.com"})

      assert is_list(addrs)
      assert length(addrs) > 0
    end

    @tag :integration
    test "lists interfaces" do
      {:ok, %{output: data, metadata: _}} =
        Net.perform("list_interfaces", %{})

      assert is_list(data)
    end
  end
end

defmodule LLMAgent.Tools.CryptoTest do
  use ExUnit.Case, async: true

  alias LLMAgent.Tools.Crypto

  describe "describe/0" do
    test "returns a string summary" do
      assert is_binary(Crypto.describe())
    end
  end

  describe "perform/2" do
    test "returns error for unknown command" do
      assert {:error, :unknown_command} == Crypto.perform("not_real", %{})
    end
  end
end

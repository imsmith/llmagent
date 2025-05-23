defmodule LLMAgent.Utils.RequireBinaryTest do
  use ExUnit.Case, async: true
  alias LLMAgent.Utils.RequireBinary

  test "returns :ok for common binary" do
    assert :ok = RequireBinary.check("sh")
  end

  test "returns error for a definitely nonexistent binary" do
    assert {:error, msg} = RequireBinary.check("definitely_not_a_real_binary_xyz123")
    assert String.contains?(msg, "not found")
  end

  test "check_many returns :ok when all binaries exist" do
    assert :ok = RequireBinary.check_many(["sh", "echo"])
  end

  test "check_many returns error for some missing binaries" do
    {:error, messages} = RequireBinary.check_many(["sh", "this_does_not_exist_foobar"])
    assert is_list(messages)
    assert Enum.any?(messages, fn m -> String.contains?(m, "this_does_not_exist_foobar") end)
  end
end

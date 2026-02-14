defmodule LLMAgent.Tools.FileTest do
  use ExUnit.Case, async: true

  alias LLMAgent.Tools.File, as: FileTool
  alias Comn.Errors.ErrorStruct

  describe "describe/0" do
    test "returns a string summary" do
      assert is_binary(FileTool.describe())
    end
  end

  describe "perform/2" do
    test "returns error for unknown command" do
      {:error, %ErrorStruct{reason: "unknown_command"}} = FileTool.perform("not_real", %{})
    end

    test "reads a file" do
      {:ok, %{output: content, metadata: %{path: "/etc/hosts"}}} =
        FileTool.perform("read", %{"path" => "/etc/hosts"})

      assert is_binary(content)
      assert byte_size(content) > 0
    end

    test "returns error for nonexistent file" do
      {:error, %ErrorStruct{reason: "file_error"}} =
        FileTool.perform("read", %{"path" => "/nonexistent/file"})
    end

    test "writes and deletes a file" do
      path = "/tmp/llmagent_test_#{:rand.uniform(100_000)}"

      {:ok, %{output: :ok, metadata: %{bytes_written: 5}}} =
        FileTool.perform("write", %{"path" => path, "content" => "hello"})

      {:ok, %{output: "hello", metadata: _}} =
        FileTool.perform("read", %{"path" => path})

      {:ok, %{output: :ok}} =
        FileTool.perform("delete", %{"path" => path})
    end
  end
end

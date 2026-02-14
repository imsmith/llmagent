defmodule LLMAgent.Tools.InotifyTest do
  use ExUnit.Case, async: true

  alias LLMAgent.Tools.Inotify
  alias Comn.Errors.ErrorStruct

  describe "describe/0" do
    test "returns a string summary" do
      assert is_binary(Inotify.describe())
    end
  end

  describe "perform/2" do
    test "returns error for unknown command" do
      {:error, %ErrorStruct{reason: "unknown_command"}} = Inotify.perform("not_real", %{})
    end

    test "watch returns result for existing path" do
      result = Inotify.perform("watch", %{"path" => "/tmp"})
      # Either success (if inotifywait installed) or missing_binary error
      assert match?({:ok, %{output: _, metadata: _}}, result) or
             match?({:error, %ErrorStruct{reason: "missing_binary"}}, result)
    end

    test "watch returns error for nonexistent path" do
      result = Inotify.perform("watch", %{"path" => "/nonexistent/path"})
      assert match?({:error, %ErrorStruct{}}, result)
    end

    test "stop returns ok" do
      {:ok, %{output: _, metadata: %{status: :stopped}}} =
        Inotify.perform("stop", %{"path" => "/tmp"})
    end
  end
end

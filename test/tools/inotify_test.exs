defmodule LLMAgent.Tools.InotifyTest do
  use ExUnit.Case, async: true

  alias LLMAgent.Tools.Inotify

  describe "describe/0" do
    test "returns a string summary" do
      assert is_binary(Inotify.describe())
    end
  end

  describe "perform/2" do
    test "returns error for unknown command" do
      assert {:error, :unknown_command} == Inotify.perform("not_real", %{})
    end

    @tag :integration
    test "successfully performs watch" do
      result = Inotify.perform("watch", %{"path" => "/tmp"})
      assert match?({:error, _}, result)
    end
  end
end

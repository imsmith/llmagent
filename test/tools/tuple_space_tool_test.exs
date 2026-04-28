defmodule LLMAgent.Tools.TupleSpaceTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias LLMAgent.Tools.TupleSpace, as: TS
  alias LLMAgent.TupleSpace
  alias Comn.Errors.ErrorStruct

  setup do
    TupleSpace.stop_space(:default)
    {:ok, _} = TupleSpace.start_space(:default)
    :ok
  end

  describe "describe/0" do
    test "returns a string mentioning the actions" do
      desc = TS.describe()
      assert is_binary(desc)
      for a <- ~w(write read take read_nowait take_nowait list_spaces create_space destroy_space) do
        assert desc =~ a, "describe missing #{a}"
      end
    end
  end

  describe "perform/2 — write and read_nowait" do
    test "write encodes JSON array to tuple; read_nowait decodes back" do
      assert {:ok, %{output: "ok"}} =
               TS.perform("write", %{"space" => "default", "tuple" => ["greeting", "hi"]})

      # write is a cast; sync via a blocking read before non-blocking ETS peek
      assert {:ok, %{output: ["greeting", "hi"]}} =
               TS.perform("read", %{"space" => "default", "pattern" => ["greeting", "_"], "timeout" => 500})

      assert {:ok, %{output: ["greeting", "hi"]}} =
               TS.perform("read_nowait", %{"space" => "default", "pattern" => ["greeting", "_"]})
    end

    test "read_nowait returns error tuple when no match" do
      assert {:error, %ErrorStruct{reason: "no_match"}} =
               TS.perform("read_nowait", %{"space" => "default", "pattern" => ["nope", "_"]})
    end
  end

  describe "perform/2 — take and take_nowait" do
    test "take_nowait removes the tuple" do
      :ok = TupleSpace.out({"task", "do it"})
      assert {:ok, %{output: ["task", "do it"]}} =
               TS.perform("take_nowait", %{"space" => "default", "pattern" => ["task", "_"]})
      assert {:error, %ErrorStruct{reason: "no_match"}} =
               TS.perform("take_nowait", %{"space" => "default", "pattern" => ["task", "_"]})
    end

    test "take with timeout blocks until match" do
      Task.start(fn ->
        Process.sleep(40)
        TupleSpace.out({"delayed", "yes"})
      end)

      assert {:ok, %{output: ["delayed", "yes"]}} =
               TS.perform("take", %{
                 "space" => "default",
                 "pattern" => ["delayed", "_"],
                 "timeout" => 1_000
               })
    end

    test "take with timeout returns timeout error" do
      assert {:error, %ErrorStruct{reason: "timeout"}} =
               TS.perform("take", %{
                 "space" => "default",
                 "pattern" => ["nope", "_"],
                 "timeout" => 50
               })
    end
  end

  describe "perform/2 — read with timeout" do
    test "non-destructive blocking read" do
      :ok = TupleSpace.out({"peek", "v"})
      assert {:ok, %{output: ["peek", "v"]}} =
               TS.perform("read", %{
                 "space" => "default",
                 "pattern" => ["peek", "_"],
                 "timeout" => 500
               })
      # Still there
      assert {:ok, %{output: ["peek", "v"]}} =
               TS.perform("read_nowait", %{"space" => "default", "pattern" => ["peek", "_"]})
    end
  end

  describe "perform/2 — space management" do
    test "create_space, list_spaces, destroy_space" do
      assert {:ok, %{output: "ok"}} = TS.perform("create_space", %{"name" => "ts_tool_named"})
      {:ok, %{output: spaces}} = TS.perform("list_spaces", %{})
      assert "ts_tool_named" in spaces
      assert {:ok, %{output: "ok"}} = TS.perform("destroy_space", %{"name" => "ts_tool_named"})
    end

    test "destroy_space on missing returns error" do
      assert {:error, %ErrorStruct{reason: "not_found"}} =
               TS.perform("destroy_space", %{"name" => "missing_ts_xyz"})
    end
  end

  describe "perform/2 — unknown action" do
    test "returns unknown_command" do
      assert {:error, %ErrorStruct{reason: "unknown_command"}} = TS.perform("nope", %{})
    end
  end
end

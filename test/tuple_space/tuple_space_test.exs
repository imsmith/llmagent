defmodule LLMAgent.TupleSpaceTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias LLMAgent.TupleSpace

  describe "space management" do
    test "start and stop a named space" do
      {:ok, pid} = TupleSpace.start_space(:test_mgmt)
      assert is_pid(pid)
      assert :test_mgmt in TupleSpace.list_spaces()
      assert :ok = TupleSpace.stop_space(:test_mgmt)
      refute :test_mgmt in TupleSpace.list_spaces()
    end

    test "duplicate space returns already_started" do
      {:ok, _} = TupleSpace.start_space(:test_dup)
      assert {:error, {:already_started, _}} = TupleSpace.start_space(:test_dup)
      TupleSpace.stop_space(:test_dup)
    end

    test "stop nonexistent space returns error" do
      assert {:error, :not_found} = TupleSpace.stop_space(:nonexistent_ts)
    end

    test "default space exists on boot" do
      assert :default in TupleSpace.list_spaces()
    end
  end

  describe "Linda operations on default space" do
    setup do
      TupleSpace.stop_space(:default)
      {:ok, _} = TupleSpace.start_space(:default)
      :ok
    end

    test "out and in_nowait" do
      :ok = TupleSpace.out({:test, "value"})
      assert {:ok, {:test, "value"}} = TupleSpace.in_nowait({:test, :_})
    end

    test "out and rd_nowait" do
      :ok = TupleSpace.out({:test, "value"})
      # rd_nowait bypasses GenServer — sync the cast first via a GenServer call
      assert {:ok, {:test, "value"}} = TupleSpace.rd({:test, :_}, 1_000)
      # Now rd_nowait sees it in ETS
      assert {:ok, {:test, "value"}} = TupleSpace.rd_nowait({:test, :_})
      assert {:ok, {:test, "value"}} = TupleSpace.rd_nowait({:test, :_})
    end

    test "blocking in_ with delayed out" do
      Task.start(fn ->
        Process.sleep(50)
        TupleSpace.out({:delayed, "arrived"})
      end)
      assert {:ok, {:delayed, "arrived"}} = TupleSpace.in_({:delayed, :_}, 1_000)
    end

    test "blocking rd with delayed out" do
      Task.start(fn ->
        Process.sleep(50)
        TupleSpace.out({:delayed, "peek"})
      end)
      assert {:ok, {:delayed, "peek"}} = TupleSpace.rd({:delayed, :_}, 1_000)
    end
  end

  describe "Linda operations on named space" do
    setup do
      {:ok, _} = TupleSpace.start_space(:named_test)
      on_exit(fn ->
        try do
          TupleSpace.stop_space(:named_test)
        catch
          _, _ -> :ok
        end
      end)
      :ok
    end

    test "out and in_nowait on named space" do
      :ok = TupleSpace.out(:named_test, {:task, "build"})
      assert {:ok, {:task, "build"}} = TupleSpace.in_nowait(:named_test, {:task, :_})
    end

    test "blocking operations on named space" do
      Task.start(fn ->
        Process.sleep(50)
        TupleSpace.out(:named_test, {:result, 42})
      end)
      assert {:ok, {:result, 42}} = TupleSpace.in_(:named_test, {:result, :_}, 1_000)
    end
  end

  describe "error handling" do
    test "operations on nonexistent space" do
      assert {:error, :space_not_found} = TupleSpace.out(:nonexistent_ts, {:a, 1})
      assert {:error, :space_not_found} = TupleSpace.in_nowait(:nonexistent_ts, {:a, :_})
      assert {:error, :space_not_found} = TupleSpace.in_(:nonexistent_ts, {:a, :_}, 100)
      assert {:error, :space_not_found} = TupleSpace.rd(:nonexistent_ts, {:a, :_}, 100)
    end

    test "rd_nowait on nonexistent space" do
      assert {:error, :space_not_found} = TupleSpace.rd_nowait(:nonexistent_ts, {:a, :_})
    end

    test "invalid pattern" do
      assert {:error, :invalid_pattern} = TupleSpace.in_nowait("not a tuple")
      assert {:error, :invalid_pattern} = TupleSpace.rd_nowait("not a tuple")
    end
  end
end

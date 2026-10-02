defmodule LLMAgent.TupleSpace.SpaceTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias LLMAgent.TupleSpace.Space

  setup do
    name = :"test_space_#{System.unique_integer([:positive])}"
    {:ok, pid} = Space.start_link(name: name)
    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)
    %{pid: pid, name: name}
  end

  describe "out + in_nowait" do
    test "write and take a tuple", %{pid: pid} do
      :ok = Space.out(pid, {:task, :pending, "build"})
      assert {:ok, {:task, :pending, "build"}} = Space.in_nowait(pid, {:task, :pending, :_})
    end

    test "in_nowait removes the tuple", %{pid: pid} do
      :ok = Space.out(pid, {:task, :pending, "build"})
      {:ok, _} = Space.in_nowait(pid, {:task, :pending, :_})
      assert {:error, :no_match} = Space.in_nowait(pid, {:task, :pending, :_})
    end

    test "in_nowait returns no_match when empty", %{pid: pid} do
      assert {:error, :no_match} = Space.in_nowait(pid, {:task, :_, :_})
    end

    test "multiple tuples, pattern selects correctly", %{pid: pid} do
      :ok = Space.out(pid, {:task, :pending, "build"})
      :ok = Space.out(pid, {:task, :done, "deploy"})
      assert {:ok, {:task, :pending, "build"}} = Space.in_nowait(pid, {:task, :pending, :_})
      assert {:ok, {:task, :done, "deploy"}} = Space.in_nowait(pid, {:task, :done, :_})
    end

    test "duplicate tuples allowed", %{pid: pid} do
      :ok = Space.out(pid, {:task, :pending, "build"})
      :ok = Space.out(pid, {:task, :pending, "build"})
      {:ok, _} = Space.in_nowait(pid, {:task, :pending, :_})
      {:ok, _} = Space.in_nowait(pid, {:task, :pending, :_})
      assert {:error, :no_match} = Space.in_nowait(pid, {:task, :pending, :_})
    end
  end

  describe "rd_nowait (direct ETS)" do
    test "reads without removing", %{pid: pid} do
      :ok = Space.out(pid, {:task, :pending, "build"})
      assert {:ok, {:task, :pending, "build"}} = Space.rd_nowait(pid, {:task, :pending, :_})
      assert {:ok, {:task, :pending, "build"}} = Space.rd_nowait(pid, {:task, :pending, :_})
    end

    test "returns no_match when empty", %{pid: pid} do
      assert {:error, :no_match} = Space.rd_nowait(pid, {:task, :_, :_})
    end
  end

  describe "invalid patterns" do
    test "in_nowait rejects non-tuple", %{pid: pid} do
      assert {:error, :invalid_pattern} = Space.in_nowait(pid, "not a tuple")
    end

    test "rd_nowait rejects non-tuple", %{pid: pid} do
      assert {:error, :invalid_pattern} = Space.rd_nowait(pid, "not a tuple")
    end
  end

  describe "info" do
    test "returns space metadata", %{pid: pid, name: name} do
      :ok = Space.out(pid, {:a, 1})
      :ok = Space.out(pid, {:b, 2})
      # Give cast time to process
      Process.sleep(10)
      info = Space.info(pid)
      assert info.name == name
      assert info.size == 2
      assert info.waiters == 0
    end
  end

  describe "blocking in_" do
    test "blocks until a matching tuple arrives", %{pid: pid} do
      Task.start(fn ->
        Process.sleep(50)
        Space.out(pid, {:task, :pending, "delayed"})
      end)
      assert {:ok, {:task, :pending, "delayed"}} = Space.in_(pid, {:task, :pending, :_}, 1_000)
    end

    test "returns immediately if match exists", %{pid: pid} do
      Space.out(pid, {:task, :pending, "ready"})
      # Ensure cast is processed
      _ = Space.info(pid)
      assert {:ok, {:task, :pending, "ready"}} = Space.in_(pid, {:task, :pending, :_}, 1_000)
    end

    test "times out when no match arrives", %{pid: pid} do
      assert {:error, :timeout} = Space.in_(pid, {:task, :pending, :_}, 50)
    end

    test "timeout 0 is equivalent to nowait", %{pid: pid} do
      assert {:error, :timeout} = Space.in_(pid, {:task, :pending, :_}, 0)
    end

    test "removes the tuple on match", %{pid: pid} do
      Task.start(fn ->
        Process.sleep(50)
        Space.out(pid, {:task, :pending, "take_me"})
      end)
      {:ok, _} = Space.in_(pid, {:task, :pending, :_}, 1_000)
      assert {:error, :no_match} = Space.in_nowait(pid, {:task, :pending, :_})
    end
  end

  describe "blocking rd" do
    test "blocks until a matching tuple arrives (non-destructive)", %{pid: pid} do
      Task.start(fn ->
        Process.sleep(50)
        Space.out(pid, {:result, 42})
      end)
      assert {:ok, {:result, 42}} = Space.rd(pid, {:result, :_}, 1_000)
      assert {:ok, {:result, 42}} = Space.rd_nowait(pid, {:result, :_})
    end

    test "times out when no match arrives", %{pid: pid} do
      assert {:error, :timeout} = Space.rd(pid, {:result, :_}, 50)
    end
  end

  describe "waiter priority" do
    test "in_ waiter takes precedence over rd waiter", %{pid: pid} do
      in_task = Task.async(fn -> Space.in_(pid, {:prize, :_}, 1_000) end)
      Process.sleep(10)
      rd_task = Task.async(fn -> Space.rd(pid, {:prize, :_}, 200) end)
      Process.sleep(10)

      Space.out(pid, {:prize, "gold"})

      assert {:ok, {:prize, "gold"}} = Task.await(in_task)
      assert {:error, :timeout} = Task.await(rd_task)
    end
  end

  describe "waiter cleanup on caller death" do
    test "removes waiter when caller dies", %{pid: pid} do
      {caller, ref} = spawn_monitor(fn ->
        Space.in_(pid, {:never, :_}, 60_000)
      end)
      Process.sleep(20)
      assert Space.info(pid).waiters == 1

      Process.exit(caller, :kill)
      receive do: ({:DOWN, ^ref, :process, _, _} -> :ok)
      Process.sleep(20)

      assert Space.info(pid).waiters == 0
    end
  end
end

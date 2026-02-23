defmodule LLMAgent.Tools.InotifyTest do
  use ExUnit.Case, async: false

  alias LLMAgent.Tools.Inotify
  alias LLMAgent.Tools.Inotify.Watcher
  alias LLMAgent.EventLog
  alias LLMAgent.EventBus
  alias Comn.Errors.ErrorStruct
  alias Comn.Events.EventStruct

  setup do
    # Start a fresh Watcher per test so watches don't leak
    name = :"watcher_#{System.unique_integer([:positive])}"
    {:ok, pid} = Watcher.start_link(name: name)

    # Create an isolated temp dir so external /tmp activity doesn't cause flakes
    dir = Path.join(System.tmp_dir!(), "inotify_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf(dir) end)

    %{watcher: name, watcher_pid: pid, dir: dir}
  end

  describe "describe/0" do
    test "returns a string summary" do
      assert is_binary(Inotify.describe())
    end
  end

  describe "Watcher GenServer" do
    test "start_watch on valid path returns watch_id", %{watcher: srv, dir: dir} do
      assert {:ok, id} = Watcher.start_watch(dir, %{}, srv)
      assert is_integer(id)
      Watcher.stop_watch(id, srv)
    end

    test "start_watch on nonexistent path returns error", %{watcher: srv} do
      assert {:error, :path_not_found} = Watcher.start_watch("/no/such/path", %{}, srv)
    end

    test "poll with unknown watch_id returns error", %{watcher: srv} do
      assert {:error, :unknown_watch} = Watcher.poll(999, srv)
    end

    test "stop with unknown watch_id returns error", %{watcher: srv} do
      assert {:error, :unknown_watch} = Watcher.stop_watch(999, srv)
    end

    test "list_watches returns active watches", %{watcher: srv, dir: dir} do
      {:ok, id} = Watcher.start_watch(dir, %{}, srv)
      {:ok, list} = Watcher.list_watches(srv)
      assert {id, dir} in list
      Watcher.stop_watch(id, srv)
    end

    test "watches detect file events", %{watcher: srv, dir: dir} do
      {:ok, id} = Watcher.start_watch(dir, %{}, srv)
      Process.sleep(200)

      path = Path.join(dir, "testfile")
      File.write!(path, "hello")
      Process.sleep(300)

      {:ok, events} = Watcher.poll(id, srv)
      assert length(events) > 0
      assert Enum.any?(events, fn e -> String.contains?(e.event, "CREATE") end)

      Watcher.stop_watch(id, srv)
    end

    test "stop returns final buffered events", %{watcher: srv, dir: dir} do
      {:ok, id} = Watcher.start_watch(dir, %{}, srv)
      Process.sleep(200)

      File.write!(Path.join(dir, "stopfile"), "data")
      Process.sleep(300)

      {:ok, final} = Watcher.stop_watch(id, srv)
      assert length(final) > 0
    end

    test "poll drains buffer", %{watcher: srv, dir: dir} do
      {:ok, id} = Watcher.start_watch(dir, %{}, srv)
      Process.sleep(200)

      File.write!(Path.join(dir, "drainfile"), "x")
      Process.sleep(300)

      {:ok, first} = Watcher.poll(id, srv)
      assert length(first) > 0

      # Second poll should be empty (buffer drained, isolated dir has no other activity)
      {:ok, second} = Watcher.poll(id, srv)
      assert second == []

      Watcher.stop_watch(id, srv)
    end
  end

  describe "Inotify.perform/2 through app Watcher" do
    test "watch starts and returns watch_id", %{dir: dir} do
      {:ok, %{output: watch_id, metadata: %{status: :watching}}} =
        Inotify.perform("watch", %{"path" => dir})

      assert is_integer(watch_id)
      Inotify.perform("stop", %{"watch_id" => watch_id})
    end

    test "watch rejects nonexistent path" do
      {:error, %ErrorStruct{reason: "not_found"}} =
        Inotify.perform("watch", %{"path" => "/nonexistent/path"})
    end

    test "poll returns events", %{dir: dir} do
      {:ok, %{output: id}} = Inotify.perform("watch", %{"path" => dir})
      Process.sleep(200)

      File.write!(Path.join(dir, "pollfile"), "test")
      Process.sleep(300)

      {:ok, %{output: events, metadata: %{count: count}}} =
        Inotify.perform("poll", %{"watch_id" => id})

      assert count > 0
      assert length(events) == count

      Inotify.perform("stop", %{"watch_id" => id})
    end

    test "stop returns final events and stops watch", %{dir: dir} do
      {:ok, %{output: id}} = Inotify.perform("watch", %{"path" => dir})
      Process.sleep(200)

      File.write!(Path.join(dir, "stopfile"), "bye")
      Process.sleep(300)

      {:ok, %{output: final, metadata: %{status: :stopped}}} =
        Inotify.perform("stop", %{"watch_id" => id})

      assert length(final) > 0

      # Polling a stopped watch should error
      {:error, %ErrorStruct{reason: "not_found"}} =
        Inotify.perform("poll", %{"watch_id" => id})
    end

    test "list returns active watches", %{dir: dir} do
      {:ok, %{output: id}} = Inotify.perform("watch", %{"path" => dir})

      {:ok, %{output: watches}} = Inotify.perform("list", %{})
      assert Enum.any?(watches, fn w -> w.watch_id == id end)

      Inotify.perform("stop", %{"watch_id" => id})
    end

    test "unknown action returns error" do
      {:error, %ErrorStruct{reason: "unknown_command"}} = Inotify.perform("not_real", %{})
    end
  end

  describe "Watcher event emission" do
    setup do
      EventLog.clear()
      :ok
    end

    test "watch emits watch_started event", %{dir: dir} do
      EventBus.subscribe("tool.inotify")

      {:ok, %{output: id}} = Inotify.perform("watch", %{"path" => dir})

      assert_receive {:event, "tool.inotify", %EventStruct{type: :watch_started} = evt}
      assert evt.data.watch_id == id
      assert evt.data.path == dir

      events = EventLog.for_topic("tool.inotify")
      assert Enum.any?(events, fn e -> e.type == :watch_started end)

      Inotify.perform("stop", %{"watch_id" => id})
    end

    test "stop emits watch_stopped event", %{dir: dir} do
      EventBus.subscribe("tool.inotify")

      {:ok, %{output: id}} = Inotify.perform("watch", %{"path" => dir})
      assert_receive {:event, "tool.inotify", %EventStruct{type: :watch_started}}

      Inotify.perform("stop", %{"watch_id" => id})

      assert_receive {:event, "tool.inotify", %EventStruct{type: :watch_stopped} = evt}
      assert evt.data.watch_id == id
    end

    test "filesystem changes emit fs_event events", %{dir: dir} do
      EventBus.subscribe("tool.inotify.event")

      {:ok, %{output: id}} = Inotify.perform("watch", %{"path" => dir})
      Process.sleep(200)

      File.write!(Path.join(dir, "evtfile"), "trigger")
      Process.sleep(300)

      assert_receive {:event, "tool.inotify.event", %EventStruct{type: :fs_event} = evt}
      assert evt.data.watch_id == id

      Inotify.perform("stop", %{"watch_id" => id})
    end
  end
end

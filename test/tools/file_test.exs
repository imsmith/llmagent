defmodule LLMAgent.Tools.FileTest do
  @moduledoc false
  use ExUnit.Case, async: false

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

  describe "tool-discovery substrate (via Dispatcher)" do
    alias LLMAgent.{Tools.File, Tools.Discovery, Tool.Dispatcher, Tool.Policy}

    setup do
      case Process.whereis(Discovery) do
        nil -> {:ok, _} = Discovery.start_link(consume_announcements: false)
        _ -> Discovery.reset!()
      end

      LLMAgent.Tool.Bindings.init_registry()
      LLMAgent.Tool.Kinds.init_registry()
      :ok = Discovery.register(File.ad())
      :ok
    end

    test "ad/0 declares both :query and :action" do
      ad = File.ad()
      assert ad.coordinate == "resource.fs.file"
      assert :query in ad.kinds
      assert :action in ad.kinds
    end

    @tag :tmp_dir
    test "dispatcher.query/4 read returns content", %{tmp_dir: dir} do
      path = Path.join(dir, "hello.txt")
      Elixir.File.write!(path, "world")

      policy = %Policy{
        allow: [%{coordinate: "resource.fs.file", kinds: [:query], actions: ["read"]}],
        fidelity_min: :authoritative
      }

      assert {:ok, "world", _meta} =
               Dispatcher.query("resource.fs.file", "read", %{"path" => path}, policy: policy)
    end

    @tag :tmp_dir
    test "dispatcher.act/5 write succeeds", %{tmp_dir: dir} do
      path = Path.join(dir, "out.txt")

      policy = %Policy{
        allow: [%{coordinate: "resource.fs.file", kinds: [:action], actions: ["write"]}],
        fidelity_min: :authoritative
      }

      assert {:ok, _ack, _meta} =
               Dispatcher.act("resource.fs.file", "write",
                 %{"path" => path, "content" => "hi"}, nil, policy: policy)

      assert Elixir.File.read!(path) == "hi"
    end
  end
end

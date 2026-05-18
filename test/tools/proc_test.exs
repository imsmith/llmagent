defmodule LLMAgent.Tools.ProcTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias LLMAgent.Tools.Proc
  alias Comn.Errors.ErrorStruct

  describe "describe/0" do
    test "returns a string summary" do
      assert is_binary(Proc.describe())
    end
  end

  describe "perform/2" do
    test "returns error for unknown command" do
      {:error, %ErrorStruct{reason: "unknown_command"}} = Proc.perform("not_real", %{})
    end

    @tag :integration
    test "successfully performs list" do
      {:ok, %{output: procs, metadata: %{count: count}}} = Proc.perform("list", %{})

      assert is_list(procs)
      assert count > 0
    end
  end

  describe "tool-discovery substrate (via Dispatcher)" do
    alias LLMAgent.{Tools.Proc, Tools.Discovery, Tool.Dispatcher, Tool.Policy}

    setup do
      case Process.whereis(Discovery) do
        nil -> {:ok, _} = Discovery.start_link(consume_announcements: false)
        _ -> Discovery.reset!()
      end

      LLMAgent.Tool.Bindings.init_registry()
      LLMAgent.Tool.Kinds.init_registry()
      :ok = Discovery.register(Proc.ad())
      :ok
    end

    test "ad/0 returns a ToolAd for resource.proc with :query kind" do
      ad = Proc.ad()
      assert ad.coordinate == "resource.proc"
      assert :query in ad.kinds
      assert ad.fidelity == :authoritative
    end

    test "dispatcher.query/4 list returns value+meta" do
      policy = %Policy{allow: ["resource.proc"], fidelity_min: :authoritative}

      assert {:ok, value, meta} =
               Dispatcher.query("resource.proc", "list", %{}, policy: policy)

      assert is_list(value) or is_map(value)
      assert is_map(meta)
    end
  end
end

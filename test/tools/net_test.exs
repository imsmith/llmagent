defmodule LLMAgent.Tools.NetTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias LLMAgent.Tools.Net
  alias Comn.Errors.ErrorStruct

  describe "describe/0" do
    test "returns a string summary" do
      assert is_binary(Net.describe())
    end
  end

  describe "perform/2" do
    test "returns error for unknown command" do
      {:error, %ErrorStruct{reason: "unknown_command"}} = Net.perform("not_real", %{})
    end

    @tag :integration
    test "resolves a hostname" do
      {:ok, %{output: addrs, metadata: %{host: "example.com"}}} =
        Net.perform("resolve", %{"host" => "example.com"})

      assert is_list(addrs)
      assert length(addrs) > 0
    end

    @tag :integration
    test "lists interfaces" do
      {:ok, %{output: data, metadata: _}} =
        Net.perform("list_interfaces", %{})

      assert is_list(data)
    end
  end

  describe "tool-discovery substrate (via Dispatcher)" do
    alias LLMAgent.{Tools.Net, Tools.Discovery, Tool.Dispatcher, Tool.Policy}

    setup do
      case Process.whereis(Discovery) do
        nil -> {:ok, _} = Discovery.start_link(consume_announcements: false)
        _ -> Discovery.reset!()
      end

      LLMAgent.Tool.Bindings.init_registry()
      LLMAgent.Tool.Kinds.init_registry()
      :ok = Discovery.register(Net.ad())
      :ok
    end

    test "ad/0 returns a ToolAd for resource.network with :query kind" do
      ad = Net.ad()
      assert ad.coordinate == "resource.network"
      assert :query in ad.kinds
      assert ad.fidelity == :authoritative
    end

    test "dispatcher.query/4 list_interfaces returns a value+meta tuple" do
      policy = %Policy{allow: ["resource.network"], fidelity_min: :authoritative}

      assert {:ok, value, meta} =
               Dispatcher.query("resource.network", "list_interfaces", %{}, policy: policy)

      assert is_list(value) or is_map(value)
      assert is_map(meta)
    end
  end
end

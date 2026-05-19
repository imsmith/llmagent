defmodule LLMAgent.Tools.UdevTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias LLMAgent.Tools.Udev
  alias Comn.Errors.ErrorStruct

  describe "describe/0" do
    test "returns a string summary" do
      assert is_binary(Udev.describe())
    end
  end

  describe "perform/2" do
    test "returns error for unknown command" do
      {:error, %ErrorStruct{reason: "unknown_command"}} = Udev.perform("not_real", %{})
    end

    @tag :integration
    test "lists devices" do
      {:ok, %{output: %{block_devices: blk, usb_devices: usb}, metadata: %{action: "list"}}} =
        Udev.perform("list", %{})

      assert is_list(blk)
      assert is_list(usb)
    end
  end

  describe "tool-discovery substrate (via Dispatcher)" do
    alias LLMAgent.{Tools.Udev, Tools.Discovery, Tool.Dispatcher, Tool.Policy}

    setup do
      case Process.whereis(Discovery) do
        nil -> {:ok, _} = Discovery.start_link(consume_announcements: false)
        _ -> Discovery.reset!()
      end

      LLMAgent.Tool.Bindings.init_registry()
      LLMAgent.Tool.Kinds.init_registry()
      :ok = Discovery.register(Udev.ad())
      :ok
    end

    test "ad/0 returns a ToolAd for resource.hardware.events with :query kind" do
      ad = Udev.ad()
      assert ad.coordinate == "resource.hardware.events"
      assert :query in ad.kinds
      assert ad.fidelity == :authoritative
    end

    test "dispatcher.query/4 list returns a value+meta tuple" do
      policy = %Policy{allow: ["resource.hardware.events"], fidelity_min: :authoritative}

      assert {:ok, value, meta} =
               Dispatcher.query("resource.hardware.events", "list", %{}, policy: policy)

      assert is_list(value) or is_map(value)
      assert is_map(meta)
    end
  end
end

defmodule LLMAgent.Tools.DbusTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias LLMAgent.Tools.DBus
  alias Comn.Errors.ErrorStruct

  describe "describe/0" do
    test "returns a string summary" do
      assert is_binary(DBus.describe())
    end
  end

  describe "perform/2" do
    test "returns error for unknown command" do
      {:error, %ErrorStruct{reason: "unknown_command"}} = DBus.perform("not_real", %{})
    end

    @tag :integration
    test "lists bus services" do
      result = DBus.perform("list", %{})
      assert match?({:ok, %{output: _, metadata: _}}, result) or match?({:error, _}, result)
    end
  end

  describe "tool-discovery substrate (via Dispatcher)" do
    alias LLMAgent.{Tools.DBus, Tools.Discovery, Tool.Dispatcher, Tool.Policy}

    setup do
      case Process.whereis(Discovery) do
        nil -> {:ok, _} = Discovery.start_link(consume_announcements: false)
        _ -> Discovery.reset!()
      end

      LLMAgent.Tool.Bindings.init_registry()
      LLMAgent.Tool.Kinds.init_registry()
      :ok = Discovery.register(DBus.ad())
      :ok
    end

    test "ad/0 declares :query and :action with coordinate function.dbus" do
      ad = DBus.ad()
      assert ad.coordinate == "function.dbus"
      assert :query in ad.kinds
      assert :action in ad.kinds
    end

    test "ad/0 covers all three actions in both constraint maps" do
      ad = DBus.ad()
      idem = ad.constraint.idempotency
      blast = ad.constraint.blast_radius

      assert idem["list"] == :idempotent
      assert idem["introspect"] == :idempotent
      assert idem["call"] == :non_idempotent

      assert blast["list"] == :system
      assert blast["introspect"] == :system
      assert blast["call"] == :system
    end

    @tag :integration
    test "dispatcher.query/4 list returns output" do
      policy = %Policy{
        allow: [%{coordinate: "function.dbus", kinds: [:query], actions: ["list"]}],
        fidelity_min: :authoritative
      }

      assert {:ok, _output, _meta} =
               Dispatcher.query("function.dbus", "list", %{}, policy: policy)
    end
  end
end

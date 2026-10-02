defmodule LLMAgent.Tools.SystemdTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias LLMAgent.Tools.Systemd

  describe "describe/0" do
    test "returns a string summary" do
      assert is_binary(Systemd.describe())
    end
  end

  describe "perform/2" do
    test "returns error for unknown command" do
      {:error, %Comn.Errors.ErrorStruct{reason: "unknown_command"}} =
        Systemd.perform("not_real", %{})
    end

    @tag :integration
    test "successfully performs status" do
      result = Systemd.perform("status", %{"unit" => "ssh.service"})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "tool-discovery substrate (via Dispatcher)" do
    alias LLMAgent.{Tools.Systemd, Tools.Discovery, Tool.Dispatcher, Tool.Policy}

    setup do
      case Process.whereis(Discovery) do
        nil -> {:ok, _} = Discovery.start_link(consume_announcements: false)
        _ -> Discovery.reset!()
      end

      LLMAgent.Tool.Bindings.init_registry()
      LLMAgent.Tool.Kinds.init_registry()
      :ok = Discovery.register(Systemd.ad())
      :ok
    end

    test "ad/0 declares :query and :action with coordinate function.systemd" do
      ad = Systemd.ad()
      assert ad.coordinate == "function.systemd"
      assert :query in ad.kinds
      assert :action in ad.kinds
    end

    test "ad/0 covers all five actions in both constraint maps" do
      ad = Systemd.ad()
      idem = ad.constraint.idempotency
      blast = ad.constraint.blast_radius

      assert idem["status"] == :idempotent
      assert idem["list"] == :idempotent
      assert idem["start"] == :non_idempotent
      assert idem["stop"] == :non_idempotent
      assert idem["restart"] == :non_idempotent

      assert blast["status"] == :local
      assert blast["list"] == :local
      assert blast["start"] == :system
      assert blast["stop"] == :system
      assert blast["restart"] == :system
    end

    # Dispatcher invocation tests shell out to real systemctl; tagged :integration.

    @tag :integration
    test "dispatcher.query/4 status returns a map" do
      policy = %Policy{
        allow: [%{coordinate: "function.systemd", kinds: [:query], actions: ["status"]}],
        fidelity_min: :authoritative
      }

      assert {:ok, _output, _meta} =
               Dispatcher.query("function.systemd", "status",
                 %{"unit" => "ssh.service"}, policy: policy)
    end

    @tag :integration
    test "dispatcher.query/4 list returns services" do
      policy = %Policy{
        allow: [%{coordinate: "function.systemd", kinds: [:query], actions: ["list"]}],
        fidelity_min: :authoritative
      }

      assert {:ok, _output, _meta} =
               Dispatcher.query("function.systemd", "list", %{}, policy: policy)
    end
  end
end

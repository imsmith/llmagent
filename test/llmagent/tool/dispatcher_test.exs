defmodule LLMAgent.Tool.DispatcherTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias LLMAgent.{ToolAd, Tool.Dispatcher, Tool.Policy, Tools.Discovery}

  defmodule StubCompute do
    @moduledoc "Test stub implementing Compute behaviour"
    @behaviour LLMAgent.Tool.Kinds.Compute
    @impl true
    def compute("double", %{"n" => n}), do: {:ok, n * 2}
    def compute(_, _), do: {:error, :unknown_action}
  end

  defmodule StubAction do
    @moduledoc "Test stub implementing Action behaviour"
    @behaviour LLMAgent.Tool.Kinds.Action
    @impl true
    def act("write", %{"v" => v}, key), do: {:ok, %{wrote: v, key: key}, %{}}
  end

  setup do
    case Process.whereis(Discovery) do
      nil -> {:ok, _} = Discovery.start_link(consume_announcements: false)
      _ -> Discovery.reset!()
    end

    LLMAgent.Tool.Bindings.init_registry()
    LLMAgent.Tool.Kinds.init_registry()
    :ok
  end

  defp ad(overrides) do
    base = %{
      id: "disp." <> Integer.to_string(System.unique_integer([:positive])),
      coordinate: "function.disp",
      kinds: [:compute],
      binding: {:module, StubCompute},
      operational: %{actions: %{}},
      constraint: %{idempotency: %{}, blast_radius: %{}},
      affordance: %{declared: [], learned: [], open: false},
      fidelity: :authoritative,
      provenance: %{source: "test", produced_at: DateTime.utc_now(), based_on: [], signature: nil},
      lease: :permanent
    }

    ToolAd.new(Map.merge(base, overrides))
  end

  describe "compute/4 — happy path" do
    test "dispatches to the :module adapter and returns the result" do
      a = ad(%{coordinate: "function.compute.double", binding: {:module, StubCompute}})
      :ok = Discovery.register(a)

      policy = %Policy{
        allow: ["function.compute.*"],
        fidelity_min: :authoritative
      }

      assert {:ok, 6} =
               Dispatcher.compute("function.compute.double", "double", %{"n" => 3}, policy: policy)
    end

    test "accepts an ad directly" do
      a = ad(%{coordinate: "function.direct", binding: {:module, StubCompute}})
      policy = %Policy{allow: ["function.direct"], fidelity_min: :authoritative}

      assert {:ok, 8} = Dispatcher.compute(a, "double", %{"n" => 4}, policy: policy)
    end
  end

  describe "policy enforcement" do
    test "deny-by-default forbids when policy.allow is empty" do
      a = ad(%{coordinate: "function.gated", binding: {:module, StubCompute}})
      :ok = Discovery.register(a)

      assert {:error, :forbidden, :not_allowed} =
               Dispatcher.compute("function.gated", "double", %{"n" => 1}, policy: %Policy{})
    end
  end

  describe "kind check" do
    test "returns :kind_not_supported when ad doesn't implement requested kind" do
      a = ad(%{coordinate: "function.action_only", kinds: [:action], binding: {:module, StubAction}})
      :ok = Discovery.register(a)

      policy = %Policy{allow: ["function.action_only"], fidelity_min: :authoritative}

      assert {:error, :kind_not_supported} =
               Dispatcher.compute("function.action_only", "x", %{}, policy: policy)
    end
  end

  describe "binding lookup" do
    test "returns :binding_not_supported for unknown binding kind" do
      a = ad(%{
        coordinate: "function.weirdbind",
        binding: {:nonexistent_binding, :something},
        kinds: [:compute]
      })

      :ok = Discovery.register(a)
      policy = %Policy{allow: ["function.weirdbind"], fidelity_min: :authoritative}

      assert {:error, :binding_not_supported} =
               Dispatcher.compute("function.weirdbind", "x", %{}, policy: policy)
    end
  end

  describe "act/5" do
    test "passes idempotency key through" do
      a = ad(%{
        coordinate: "function.acttest",
        kinds: [:action],
        binding: {:module, StubAction}
      })

      :ok = Discovery.register(a)
      policy = %Policy{allow: ["function.acttest"], fidelity_min: :authoritative}

      assert {:ok, %{wrote: 7, key: "k1"}, %{}} =
               Dispatcher.act("function.acttest", "write", %{"v" => 7}, "k1", policy: policy)
    end
  end

  describe "generate/4" do
    test "dispatches :generate via adapter.generate/4" do
      defmodule StubGen do
        @moduledoc false
        @behaviour LLMAgent.Tool.Adapter
        @impl true
        def generate(payload, action, _args, _opts) do
          {:ok, "answer for #{action}", %{model: payload.model}}
        end
      end

      :ok = LLMAgent.Tool.Bindings.register(:stub_gen, StubGen)

      a = ad(%{
        id: "gen.test.1",
        coordinate: "compute.llm.chat",
        kinds: [:generate],
        binding: {:stub_gen, %{model: "stub-1"}}
      })

      :ok = Discovery.update(a)

      policy = %Policy{allow: ["compute.llm.*"], fidelity_min: :authoritative}

      assert {:ok, "answer for chat", %{model: "stub-1"}} =
               Dispatcher.generate(a, "chat", %{messages: []}, policy: policy)
    end
  end

  describe "telemetry" do
    test "emits [:llmagent, :tool, :compute] on dispatch" do
      a = ad(%{coordinate: "function.tele", binding: {:module, StubCompute}})
      :ok = Discovery.register(a)

      policy = %Policy{allow: ["function.tele"], fidelity_min: :authoritative}

      handler_id = "test-handler-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler_id,
        [:llmagent, :tool, :compute],
        fn _name, _measurements, metadata, _config -> send(parent, {:telemetry, metadata}) end,
        nil
      )

      _ = Dispatcher.compute("function.tele", "double", %{"n" => 2}, policy: policy)

      assert_receive {:telemetry, %{coordinate: "function.tele", action: "double"}}, 500

      :telemetry.detach(handler_id)
    end
  end
end

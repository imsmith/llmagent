defmodule LLMAgent.Tool.ApprovalFlowTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias LLMAgent.{ToolAd, Tool.Dispatcher, Tool.Policy, Tools.Discovery, EventBus}

  defmodule StubAction do
    @moduledoc false
    @behaviour LLMAgent.Tool.Kinds.Action
    @impl true
    def act("do", _args, _key), do: {:ok, :acked, %{}}
  end

  setup do
    case Process.whereis(Discovery) do
      nil -> {:ok, _} = Discovery.start_link(consume_announcements: false)
      _ -> Discovery.reset!()
    end

    LLMAgent.Tool.Bindings.init_registry()
    LLMAgent.Tool.Kinds.init_registry()
    Dispatcher.init_approvals()

    ad =
      ToolAd.new(%{
        id: "appr.test",
        coordinate: "function.appr",
        kinds: [:action],
        binding: {:module, StubAction},
        operational: %{actions: %{"do" => %{inputs: %{}, outputs: %{}, pre: nil, post: nil}}},
        constraint: %{idempotency: %{"do" => :non_idempotent}, blast_radius: %{"do" => :local}},
        affordance: %{declared: [], learned: [], open: false},
        fidelity: :authoritative,
        provenance: %{source: "test", produced_at: DateTime.utc_now(), based_on: [], signature: nil},
        lease: :permanent,
        meta: %{}
      })

    :ok = Discovery.register(ad)
    {:ok, ad: ad}
  end

  describe "Policy.requires_approval?/4" do
    test "true when a require_approval rule matches", %{ad: ad} do
      policy = %Policy{require_approval: ["function.appr"]}
      assert Policy.requires_approval?(policy, ad, :action, "do")
    end

    test "false when no rule matches", %{ad: ad} do
      assert not Policy.requires_approval?(%Policy{}, ad, :action, "do")
    end
  end

  describe "Dispatcher with require_approval" do
    test "blocks until approve/2 :allow, then completes" do
      policy = %Policy{
        allow: ["function.appr"],
        require_approval: ["function.appr"],
        fidelity_min: :authoritative
      }

      EventBus.subscribe("tool.pending_approval")

      caller = self()

      Task.start(fn ->
        result =
          Dispatcher.act("function.appr", "do", %{"k" => "v"}, nil,
            policy: policy, approval_timeout: 1_000)

        send(caller, {:dispatch_result, result})
      end)

      assert_receive {:event, "tool.pending_approval", event}, 500
      :ok = Dispatcher.approve(event.data.id, :allow)

      assert_receive {:dispatch_result, {:ok, :acked, _}}, 500
    end

    test "deny returns :user_denied" do
      policy = %Policy{
        allow: ["function.appr"],
        require_approval: ["function.appr"],
        fidelity_min: :authoritative
      }

      EventBus.subscribe("tool.pending_approval")
      caller = self()

      Task.start(fn ->
        result =
          Dispatcher.act("function.appr", "do", %{}, nil,
            policy: policy, approval_timeout: 1_000)

        send(caller, {:dispatch_result, result})
      end)

      assert_receive {:event, "tool.pending_approval", event}, 500
      :ok = Dispatcher.approve(event.data.id, :deny)

      assert_receive {:dispatch_result, {:error, :forbidden, :user_denied}}, 500
    end

    test "timeout returns :approval_timeout" do
      policy = %Policy{
        allow: ["function.appr"],
        require_approval: ["function.appr"],
        fidelity_min: :authoritative
      }

      assert {:error, :forbidden, :approval_timeout} =
               Dispatcher.act("function.appr", "do", %{}, nil,
                 policy: policy, approval_timeout: 50)
    end
  end

  describe "approve/2" do
    test "returns :not_found for unknown id" do
      assert {:error, :not_found} = Dispatcher.approve("appr_bogus", :allow)
    end
  end
end

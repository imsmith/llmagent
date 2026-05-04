defmodule LLMAgent.Tool.PolicyTest do
  @moduledoc "Tests for LLMAgent.Tool.Policy."
  use ExUnit.Case, async: true
  alias LLMAgent.{ToolAd, Tool.Policy}

  defp ad(overrides \\ %{}) do
    base = %{
      id: "test.ad",
      coordinate: "function.example",
      kinds: [:compute],
      binding: {:module, FakeMod},
      operational: %{actions: %{}},
      constraint: %{idempotency: %{}, blast_radius: %{}},
      affordance: %{declared: [], learned: [], open: false},
      fidelity: :authoritative,
      provenance: %{source: "test", produced_at: DateTime.utc_now(), based_on: [], signature: nil},
      lease: :permanent
    }

    ToolAd.new(Map.merge(base, overrides))
  end

  describe "decide/4 — allow/deny" do
    test "deny-by-default: empty allow forbids" do
      policy = %Policy{}
      assert {:error, :forbidden, :not_allowed} =
               Policy.decide(policy, ad(), :compute, "anything")
    end

    test "matching allow rule permits" do
      policy = %Policy{
        allow: [%{coordinate: "function.example", kinds: :any, actions: :any}]
      }
      assert :ok = Policy.decide(policy, ad(), :compute, "anything")
    end

    test "bare-string allow rule desugars" do
      policy = %Policy{allow: ["function.example"]}
      assert :ok = Policy.decide(policy, ad(), :compute, "anything")
    end

    test "explicit deny overrides allow" do
      policy = %Policy{
        allow: ["function.*"],
        deny:  [%{coordinate: "function.example", kinds: [:compute], actions: :any}]
      }
      assert {:error, :forbidden, :explicit_deny} =
               Policy.decide(policy, ad(), :compute, "x")
    end

    test "kinds filter narrows" do
      policy = %Policy{
        allow: [%{coordinate: "function.example", kinds: [:query], actions: :any}]
      }
      assert {:error, :forbidden, :not_allowed} =
               Policy.decide(policy, ad(), :compute, "x")
    end

    test "actions filter narrows" do
      policy = %Policy{
        allow: [%{coordinate: "function.example", kinds: :any, actions: ["only-this"]}]
      }
      assert :ok = Policy.decide(policy, ad(), :compute, "only-this")
      assert {:error, :forbidden, :not_allowed} =
               Policy.decide(policy, ad(), :compute, "other")
    end
  end

  describe "decide/4 — fidelity floor" do
    test "ad below fidelity_min is forbidden" do
      policy = %Policy{
        allow: ["function.example"],
        fidelity_min: :authoritative
      }
      assert {:error, :forbidden, :fidelity_too_low} =
               Policy.decide(policy, ad(%{fidelity: :trained}), :compute, "x")
    end

    test "ad at or above fidelity_min is allowed" do
      policy = %Policy{
        allow: ["function.example"],
        fidelity_min: :trained
      }
      assert :ok = Policy.decide(policy, ad(%{fidelity: :trained}), :compute, "x")
      assert :ok = Policy.decide(policy, ad(%{fidelity: :authoritative}), :compute, "x")
    end
  end

  describe "decide/4 — provenance" do
    test "source filter excludes non-matching" do
      policy = %Policy{
        allow: ["function.example"],
        provenance: %{source: ["trusted"], signed: false}
      }
      assert {:error, :forbidden, :provenance} =
               Policy.decide(policy, ad(), :compute, "x")
    end

    test "source filter accepts matching" do
      policy = %Policy{
        allow: ["function.example"],
        provenance: %{source: ["test"], signed: false}
      }
      assert :ok = Policy.decide(policy, ad(), :compute, "x")
    end

    test "signed required + signature missing is forbidden" do
      policy = %Policy{
        allow: ["function.example"],
        provenance: %{source: :any, signed: true}
      }
      assert {:error, :forbidden, :unsigned} =
               Policy.decide(policy, ad(), :compute, "x")
    end
  end

  describe "intersect/2" do
    test "merging policies takes the more restrictive bounds" do
      base = %Policy{
        allow: ["function.*"],
        fidelity_min: :trained
      }

      override = %Policy{
        allow: ["function.example"],
        fidelity_min: :authoritative,
        provenance: %{source: ["trusted"], signed: false}
      }

      merged = Policy.intersect(base, override)

      # The merged policy is the override (more restrictive) intersected with base allow
      assert merged.fidelity_min == :authoritative
      assert merged.provenance == %{source: ["trusted"], signed: false}
    end

    test "never broadens the allow set" do
      narrow = %Policy{allow: [%{coordinate: "function.specific", kinds: :any, actions: :any}]}
      broad  = %Policy{allow: [
                 %{coordinate: "function.*",  kinds: :any, actions: :any},
                 %{coordinate: "resource.*",  kinds: :any, actions: :any}
               ]}

      # narrow ∩ broad — must keep the narrower set, not adopt the broader one
      merged_a = Policy.intersect(narrow, broad)
      assert length(merged_a.allow) == 1
      assert hd(merged_a.allow).coordinate == "function.specific"

      # broad ∩ narrow — must also narrow
      merged_b = Policy.intersect(broad, narrow)
      assert length(merged_b.allow) == 1
      assert hd(merged_b.allow).coordinate == "function.specific"
    end
  end

  describe "from_legacy_or_struct/1" do
    test "list of atoms desugars to legacy.* coordinates" do
      policy = Policy.from_legacy_or_struct([:bash, :web])

      assert policy.fidelity_min == :authoritative
      assert Enum.any?(policy.allow, &match?(%{coordinate: "legacy.bash"}, &1))
      assert Enum.any?(policy.allow, &match?(%{coordinate: "legacy.web"}, &1))
    end

    test "passes %Policy{} through" do
      p = %Policy{allow: ["x"]}
      assert ^p = Policy.from_legacy_or_struct(p)
    end
  end
end

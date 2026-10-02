defmodule LLMAgent.ToolAdTest do
  @moduledoc false
  use ExUnit.Case, async: true
  alias LLMAgent.ToolAd

  describe "new/1" do
    test "builds an ad with required fields" do
      now = DateTime.utc_now()

      ad = ToolAd.new(%{
        id: "builtin.example",
        coordinate: "function.example",
        kinds: [:compute],
        binding: {:module, SomeMod},
        operational: %{actions: %{}},
        constraint: %{idempotency: %{}, blast_radius: %{}},
        affordance: %{declared: [], learned: [], open: false},
        fidelity: :authoritative,
        provenance: %{source: "test", produced_at: now, based_on: [], signature: nil},
        lease: :permanent,
        meta: %{}
      })

      assert ad.id == "builtin.example"
      assert ad.coordinate == "function.example"
      assert ad.kinds == [:compute]
      assert ad.fidelity == :authoritative
      assert ad.lease == :permanent
    end

    test "raises on missing required keys" do
      assert_raise ArgumentError, fn ->
        ToolAd.new(%{coordinate: "x"})
      end
    end
  end
end

defmodule LLMAgent.Discovery.WireTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias LLMAgent.Discovery.Wire
  alias LLMAgent.ToolAd

  defp sample_ad do
    ToolAd.new(%{
      id: "mdns:_llama._tcp:host:8080",
      coordinate: "compute.llm.chat",
      kinds: [:generate],
      binding: {:openai_chat, %{api_host: "http://10.0.0.1:8080", model: "m1"}},
      operational: %{actions: %{"chat" => %{concurrency: 4}}, model_id: "m1"},
      constraint: %{idempotency: %{}, blast_radius: %{}},
      affordance: %{declared: [%{intent: :long_context, n_ctx: 262_144}], learned: [], open: true},
      fidelity: :authoritative,
      provenance: %{
        source: "mdns/_llama._tcp",
        produced_at: ~U[2026-05-07 15:00:00Z],
        based_on: [],
        signature: nil
      },
      lease: {:expires_at, ~U[2026-05-07 15:01:00Z]}
    })
  end

  test "decodes a register event into a ToolAd" do
    edn =
      ~s|{:event :register :ad {:id "x.1" :coordinate "compute.llm.chat" :kinds [:generate] :binding [:openai_chat {:api_host "http://h:8080" :model "m"}] :operational {:actions {} :model_id "m"} :constraint {:idempotency {} :blast_radius {}} :affordance {:declared [] :learned [] :open true} :fidelity :authoritative :provenance {:source "s" :produced_at "2026-05-07T15:00:00Z" :based_on [] :signature nil} :lease [:expires_at "2026-05-07T15:01:00Z"]}}|

    assert {:ok, {:register, %ToolAd{} = ad}} = Wire.decode(edn)
    assert ad.id == "x.1"
    assert ad.kinds == [:generate]
    assert {:openai_chat, %{api_host: "http://h:8080", model: "m"}} = ad.binding
    assert {:expires_at, %DateTime{}} = ad.lease
  end

  test "decodes an expire event" do
    edn = ~s|{:event :expire :id "x.1"}|
    assert {:ok, {:expire, "x.1"}} = Wire.decode(edn)
  end

  test "returns an error for malformed edn" do
    assert {:error, _} = Wire.decode("not valid edn")
  end

  test "returns an error for unknown event" do
    edn = ~s|{:event :poke :id "x"}|
    assert {:error, {:unknown_event, :poke}} = Wire.decode(edn)
  end

  test "encode/decode round-trips a sample ad" do
    ad = sample_ad()
    {:ok, line} = Wire.encode_register(ad)
    assert {:ok, {:register, decoded}} = Wire.decode(line)
    assert decoded.id == ad.id
    assert decoded.kinds == ad.kinds
    assert decoded.lease == ad.lease
  end
end

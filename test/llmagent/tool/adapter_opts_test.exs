defmodule LLMAgent.Tool.AdapterOptsTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias LLMAgent.{ToolAd, Tool.Bindings, Tool.Dispatcher, Tool.Policy}

  # Records the opts it was handed so the test can assert on them.
  defmodule Spy do
    @moduledoc false
    @behaviour LLMAgent.Tool.Adapter

    @impl true
    def query(_payload, _action, _args, opts) do
      {:ok, Keyword.get(opts, :ad), %{}}
    end
  end

  setup do
    :ok = Bindings.register(:spy, Spy)
    on_exit(fn -> Bindings.unregister(:spy) end)
    :ok
  end

  defp spy_ad do
    ToolAd.new(%{
      id: "spy.1",
      coordinate: "function.spy",
      kinds: [:query],
      binding: {:spy, %{}},
      operational: %{actions: %{}},
      constraint: %{idempotency: %{}, blast_radius: %{}},
      affordance: %{declared: [], learned: [], open: false},
      fidelity: :authoritative,
      provenance: %{
        source: "test",
        produced_at: ~U[2026-08-05 00:00:00Z],
        based_on: [],
        signature: nil
      },
      lease: :permanent
    })
  end

  test "the adapter receives the resolved ad in opts" do
    ad = spy_ad()
    policy = %Policy{allow: ["function.spy"], fidelity_min: :speculative}

    assert {:ok, %ToolAd{} = seen, _meta} =
             Dispatcher.query(ad, "anything", %{}, policy: policy)

    assert seen.id == "spy.1"
  end
end

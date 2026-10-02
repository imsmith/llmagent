defmodule LLMAgent.AnemosTest do
  use ExUnit.Case, async: false

  alias LLMAgent.{ToolAd, Tool.Policy, Tools.Discovery}

  defmodule Doubler do
    @moduledoc false
    @behaviour LLMAgent.Tool.Kinds.Compute
    @behaviour LLMAgent.Tool.Kinds.Query

    @impl true
    def compute("double", %{"n" => n}), do: {:ok, n * 2}
    def compute(_, _), do: {:error, :unknown_action}

    @impl true
    def query("describe", args), do: {:ok, "doubler", %{args: args}}
    def query(_, _), do: {:error, :unknown_action}
  end

  defp ad(coordinate, kinds, actions) do
    ToolAd.new(%{
      id: "test.#{coordinate}",
      coordinate: coordinate,
      kinds: kinds,
      binding: {:module, Doubler},
      operational: %{actions: Map.new(actions, &{&1, %{}})},
      constraint: %{
        idempotency: Map.new(actions, &{&1, :idempotent}),
        blast_radius: Map.new(actions, &{&1, :none})
      },
      affordance: %{declared: [], learned: [], open: false},
      fidelity: :authoritative,
      provenance: %{source: "test", produced_at: DateTime.utc_now(), based_on: [], signature: nil},
      lease: :permanent
    })
  end

  setup context do
    Discovery.reset!()

    :ok =
      Discovery.register(ad("function.test.double", [:compute, :query], ["double", "describe"]))

    rt = :"an_#{:erlang.phash2(context.test)}"
    start_supervised!({Anemos.Runtime, name: rt})

    policy =
      Map.get(context, :policy, %Policy{allow: ["function.test.*"], fidelity_min: :authoritative})

    start_supervised!({LLMAgent.Anemos, runtime: rt, policy: policy})
    %{rt: rt}
  end

  defp run(rt, source) do
    :ok = Anemos.Runtime.load(rt, source)
    {:ok, results} = Anemos.Runtime.dispatch(rt, "EV")
    results
  end

  test "a discovered tool is a module, its action a verb, its arguments key-value pairs", %{
    rt: rt
  } do
    assert [%{type: :log, value: 10}] =
             run(rt, ~s|rule r { when EV { log [FUNCTION_TEST_DOUBLE::double :n 5] } }|)
  end

  test "the side-effect-free kind answers first, and metadata is dropped", %{rt: rt} do
    assert [%{type: :log, value: "doubler"}] =
             run(rt, ~s|rule r { when EV { log [FUNCTION_TEST_DOUBLE::describe] } }|)
  end

  @tag policy: %Policy{allow: ["something.else"]}
  test "the attachment's policy decides", %{rt: rt} do
    assert [{:error, reason}] =
             run(rt, ~s|rule r { when EV { [FUNCTION_TEST_DOUBLE::double :n 5] } }|)

    assert reason == {:forbidden, :not_allowed}
  end

  test "an odd argument list is refused before anything is dispatched", %{rt: rt} do
    assert [{:error, :args_must_be_key_value_pairs}] =
             run(rt, ~s|rule r { when EV { [FUNCTION_TEST_DOUBLE::double 5] } }|)
  end

  test "an action the tool does not have", %{rt: rt} do
    assert [{:error, :unknown_action}] =
             run(rt, ~s|rule r { when EV { [FUNCTION_TEST_DOUBLE::triple :n 5] } }|)
  end

  test "a tool that arrives later becomes callable", %{rt: rt} do
    :ok = Discovery.register(ad("function.test.late", [:compute], ["double"]))
    Process.sleep(50)

    assert [%{type: :log, value: 4}] =
             run(rt, ~s|rule r { when EV { log [FUNCTION_TEST_LATE::double :n 2] } }|)
  end

  test "verbs/0 says what a policy could call" do
    assert [
             %{
               module: "FUNCTION_TEST_DOUBLE",
               verb: "describe",
               coordinate: "function.test.double",
               kinds: [:compute, :query],
               idempotency: :idempotent,
               blast_radius: :none
             },
             %{verb: "double"}
           ] = LLMAgent.Anemos.verbs()
  end
end

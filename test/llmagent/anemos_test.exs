defmodule LLMAgent.AnemosTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LLMAgent.{ToolAd, Tool.Policy, Tools.Discovery}

  defmodule Doubler do
    @moduledoc false
    @behaviour LLMAgent.Tool.Kinds.Compute
    @behaviour LLMAgent.Tool.Kinds.Query

    @impl true
    def compute("double", %{"n" => n}), do: {:ok, n * 2}
    def compute("who", _), do: {:ok, :compute_side}
    def compute("boom", _), do: raise(ArgumentError, "s3cret in the message")
    def compute("slow", %{"ms" => ms}), do: Process.sleep(ms) && {:ok, :late}

    def compute("reenter", %{"runtime" => rt}),
      do: Anemos.Runtime.dispatch(String.to_existing_atom(rt), "EV")

    def compute(_, _), do: {:error, :unknown_action}

    @impl true
    def query("describe", args), do: {:ok, "doubler", %{args: args}}
    def query("who", _), do: {:ok, :query_side, %{}}
    def query(_, _), do: {:error, :unknown_action}
  end

  defmodule Other do
    @moduledoc false
    @behaviour LLMAgent.Tool.Kinds.Compute
    @impl true
    def compute(_, _), do: {:ok, :other}
  end

  defp ad(coordinate, kinds, actions, module \\ Doubler) do
    ToolAd.new(%{
      id: "test.#{coordinate}",
      coordinate: coordinate,
      kinds: kinds,
      binding: {:module, module},
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

  @allow %Policy{allow: ["function.test.*"], fidelity_min: :authoritative}

  setup context do
    Discovery.reset!()

    :ok =
      Discovery.register(ad("function.test.double", [:compute, :query], ["double", "describe"]))

    rt = :"an_#{:erlang.phash2(context.test)}"
    start_supervised!({Anemos.Runtime, name: rt})
    policy = Map.get(context, :policy, @allow)
    att = start_supervised!({LLMAgent.Anemos, runtime: rt, policy: policy, verb_timeout_ms: 300})
    %{rt: rt, att: att}
  end

  defp run(rt, source) do
    :ok = Anemos.Runtime.load(rt, source)
    {:ok, results} = Anemos.Runtime.dispatch(rt, "EV")
    results
  end

  defp await_module(rt, name, tries \\ 100) do
    cond do
      name in Anemos.Runtime.describe(rt).modules -> :ok
      tries == 0 -> flunk("#{name} never registered")
      true -> Process.sleep(10) && await_module(rt, name, tries - 1)
    end
  end

  test "a discovered tool is a module, its action a verb, its arguments key-value pairs", %{
    rt: rt
  } do
    assert [%{type: :log, value: 10}] =
             run(rt, ~s|rule r { when EV { log [FUNCTION_TEST_DOUBLE::double :n 5] } }|)
  end

  test "metadata is dropped from a query's answer", %{rt: rt} do
    assert [%{type: :log, value: "doubler"}] =
             run(rt, ~s|rule r { when EV { log [FUNCTION_TEST_DOUBLE::describe] } }|)
  end

  test "the side-effect-free kind answers first", %{rt: rt} do
    assert [%{type: :log, value: :query_side}] =
             run(rt, ~s|rule r { when EV { log [FUNCTION_TEST_DOUBLE::who] } }|)
  end

  @tag policy: %Policy{allow: ["something.else"]}
  test "the attachment's policy decides", %{rt: rt} do
    assert [{:error, {:forbidden, :not_allowed}}] =
             run(rt, ~s|rule r { when EV { [FUNCTION_TEST_DOUBLE::double :n 5] } }|)
  end

  test "a policy that requires approval is refused at start", %{rt: rt} do
    start_supervised!(
      Supervisor.child_spec({Anemos.Runtime, name: :"#{rt}_other"}, id: :other_rt)
    )

    assert {:error, reason} =
             start_supervised(
               Supervisor.child_spec(
                 {LLMAgent.Anemos,
                  runtime: :"#{rt}_other", policy: %Policy{require_approval: ["x"]}},
                 id: :approving
               )
             )

    assert inspect(reason) =~ "require_approval_not_supported"
  end

  test "an odd argument list is refused before anything is dispatched", %{rt: rt} do
    assert [{:error, :args_must_be_key_value_pairs}] =
             run(rt, ~s|rule r { when EV { [FUNCTION_TEST_DOUBLE::double 5] } }|)
  end

  test "an action the tool does not have", %{rt: rt} do
    assert [{:error, :unknown_action}] =
             run(rt, ~s|rule r { when EV { [FUNCTION_TEST_DOUBLE::triple :n 5] } }|)
  end

  describe "a tool is not trusted with the dispatcher" do
    test "one that raises is an error, without its message", %{rt: rt} do
      dispatcher = Process.whereis(:"#{rt}.dispatcher")

      log =
        capture_log(fn ->
          assert [{:error, {:tool_crashed, ArgumentError}}] =
                   run(rt, ~s|rule r { when EV { [FUNCTION_TEST_DOUBLE::boom] } }|)
        end)

      refute log =~ "s3cret"
      assert Process.whereis(:"#{rt}.dispatcher") == dispatcher
    end

    test "one that is slow is cut off at the deadline", %{rt: rt} do
      assert [{:error, :timeout}] =
               run(rt, ~s|rule r { when EV { [FUNCTION_TEST_DOUBLE::slow :ms 2000] } }|)
    end

    test "one that calls back into the runtime does not deadlock it", %{rt: rt} do
      assert [{:error, :timeout}] =
               run(
                 rt,
                 ~s|rule r { when EV { [FUNCTION_TEST_DOUBLE::reenter :runtime "#{rt}"] } }|
               )

      assert {:ok, _} = Anemos.Runtime.dispatch(rt, "OTHER")
    end
  end

  test "a tool that arrives later becomes callable", %{rt: rt} do
    :ok = Discovery.register(ad("function.test.late", [:compute], ["double"]))
    await_module(rt, "FUNCTION_TEST_LATE")

    assert [%{type: :log, value: 4}] =
             run(rt, ~s|rule r { when EV { log [FUNCTION_TEST_LATE::double :n 2] } }|)
  end

  test "a coordinate that collides with a bound name does not take it over", %{rt: rt} do
    log =
      capture_log(fn ->
        :ok = Discovery.register(ad("function.test_double", [:compute], ["double"], Other))
        Process.sleep(50)
      end)

    assert log =~ "function.test_double would be FUNCTION_TEST_DOUBLE"

    assert [%{type: :log, value: 10}] =
             run(rt, ~s|rule r { when EV { log [FUNCTION_TEST_DOUBLE::double :n 5] } }|)
  end

  test "a tool that leaves releases its name, and the name stays bound", %{rt: rt} do
    :ok = Discovery.unregister("test.function.test.double")
    Process.sleep(50)

    assert [{:error, {:unknown_tool, "FUNCTION_TEST_DOUBLE"}}] =
             run(rt, ~s|rule r { when EV { [FUNCTION_TEST_DOUBLE::double :n 5] } }|)
  end

  test "stopping the attachment detaches every tool verb", %{rt: rt} do
    :ok = stop_supervised(LLMAgent.Anemos)

    assert [{:error, :detached}] =
             run(rt, ~s|rule r { when EV { [FUNCTION_TEST_DOUBLE::double :n 5] } }|)
  end

  test "verbs/0 says what a policy could call" do
    :ok = Discovery.register(ad("function.test.blank", [:compute], []))

    assert [
             %{module: "FUNCTION_TEST_BLANK", verb: "*", idempotency: nil},
             %{
               module: "FUNCTION_TEST_DOUBLE",
               verb: "describe",
               coordinate: "function.test.double",
               kinds: [:compute, :query],
               idempotency: :idempotent,
               blast_radius: :none
             },
             %{verb: "double"}
           ] =
             Enum.filter(
               LLMAgent.Anemos.verbs(),
               &String.starts_with?(&1.coordinate, "function.test.")
             )
  end
end

defmodule LLMAgent.AnemosDescribeTest do
  use ExUnit.Case, async: false

  alias LLMAgent.{ToolAd, Tools.Discovery}

  test "describe/1 answers from the ad, per name" do
    Discovery.reset!()

    :ok =
      Discovery.register(
        ToolAd.new(%{
          id: "d.1",
          coordinate: "function.test.describe",
          kinds: [:compute],
          binding: {:module, Enum},
          operational: %{actions: %{"double" => %{}, "halve" => %{}}},
          constraint: %{idempotency: %{"double" => :idempotent}, blast_radius: %{}},
          affordance: %{
            declared: [%{intent: "arithmetic on demand", suits: "tests", avoid_when: nil}],
            learned: [],
            open: false
          },
          fidelity: :authoritative,
          provenance: %{
            source: "test",
            produced_at: DateTime.utc_now(),
            based_on: [],
            signature: nil
          },
          lease: :permanent
        })
      )

    assert %{
             look: "FUNCTION_TEST_DESCRIBE — function.test.describe: arithmetic on demand",
             recon: %{
               coordinate: "function.test.describe",
               kinds: [:compute],
               idempotency: %{"double" => :idempotent}
             },
             choices: %{verbs: ["double", "halve"]}
           } = LLMAgent.Anemos.describe("FUNCTION_TEST_DESCRIBE")

    assert %{look: "NOPE — no tool" <> _} = LLMAgent.Anemos.describe("NOPE")
  end
end

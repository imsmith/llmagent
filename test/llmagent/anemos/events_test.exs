defmodule LLMAgent.Anemos.EventsTest do
  use ExUnit.Case, async: false

  alias Comn.Events.EventStruct
  alias LLMAgent.{EventBus, Events, ToolAd, Tool.Policy, Tools.Discovery}

  setup context do
    Discovery.reset!()
    rt = :"ae_#{:erlang.phash2(context.test)}"
    start_supervised!({Anemos.Runtime, name: rt})

    opts = Keyword.merge([runtime: rt, policy: %Policy{}], Map.get(context, :opts, []))
    start_supervised!({LLMAgent.Anemos, opts})
    %{rt: rt}
  end

  defp await(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("never happened")
      true -> Process.sleep(10) && await(fun, tries - 1)
    end
  end

  defp fired(rt), do: for(%{event: e} <- Anemos.Runtime.trace(rt, 200), do: e)

  # Other things on this machine announce themselves while a test runs, so
  # the entry wanted is found by name, not by being the newest.
  defp entry(rt, event), do: Enum.find(Anemos.Runtime.trace(rt, 200), &(&1.event == event))

  test "a substrate event is dispatched by topic, with its data as facts", %{rt: rt} do
    :ok =
      Anemos.Runtime.load(rt, """
      rule seen {
        context "tool.inotify" {
          when TOOL_INOTIFY_EVENT { log ?path }
        }
      }
      rule elsewhere {
        context "hub" {
          when TOOL_INOTIFY_EVENT { log "wrong room" }
        }
      }
      """)

    Events.emit(:fs_event, "tool.inotify.event", %{path: "/x", event: "CREATE"}, :test)
    await(fn -> "TOOL_INOTIFY_EVENT" in fired(rt) end)

    assert %{steps: steps, results: [%{type: :log, value: "/x"}]} =
             entry(rt, "TOOL_INOTIFY_EVENT")

    assert Enum.sort(Enum.map(steps, &{&1.rule, &1.outcome})) ==
             [{"elsewhere", :context_mismatch}, {"seen", :fired}]
  end

  test "the event's topic, type, source and id are facts too", %{rt: rt} do
    :ok = Anemos.Runtime.load(rt, ~s|rule r { when AGENT_MESSAGE { log ?type } }|)
    Events.emit(:message, "agent.message", %{text: "hi"}, :test)
    await(fn -> "AGENT_MESSAGE" in fired(rt) end)
    assert %{results: [%{type: :log, value: "message"}]} = entry(rt, "AGENT_MESSAGE")
  end

  test "a tool arriving is an event with its coordinate as context", %{rt: rt} do
    :ok =
      Anemos.Runtime.load(rt, """
      rule r { context "function" { when TOOL_ADDED { log ?coordinate } } }
      """)

    :ok =
      Discovery.register(
        ToolAd.new(%{
          id: "t.1",
          coordinate: "function.test.x",
          kinds: [:compute],
          binding: {:module, Enum},
          operational: %{actions: %{}},
          constraint: %{idempotency: %{}, blast_radius: %{}},
          affordance: %{declared: [], learned: [], open: false},
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

    await(fn ->
      Enum.any?(Anemos.Runtime.trace(rt, 200), &(&1.context_path == "function.test.x"))
    end)

    assert %{results: [%{type: :log, value: "function.test.x"}]} =
             Enum.find(Anemos.Runtime.trace(rt, 200), &(&1.context_path == "function.test.x"))
  end

  test "emit publishes on the bus and is not fed back into the runtime", %{rt: rt} do
    EventBus.subscribe("system.config.network")

    :ok =
      Anemos.Runtime.load(rt, """
      rule r {
        when EV {
          emit [EVENT::ip.addr.changed :iface "eth0"] to channel(system.config.network)
        }
      }
      rule loop { when SYSTEM_CONFIG_NETWORK { log "fed back" } }
      """)

    Anemos.Runtime.dispatch(rt, "EV")

    assert_receive {:event, "system.config.network",
                    %EventStruct{
                      source: {LLMAgent.Anemos.Channel, ^rt},
                      data: %{
                        payload: %{"event" => "ip.addr.changed", "iface" => "eth0"},
                        rule: "r"
                      }
                    }}

    Process.sleep(50)
    refute "SYSTEM_CONFIG_NETWORK" in fired(rt)
  end

  defmodule Emitter do
    @moduledoc false
    @behaviour LLMAgent.Tool.Kinds.Compute
    @impl true
    def compute("tick", _args) do
      LLMAgent.Events.emit(:tick, "loop.tick", %{}, :emitter)
      {:ok, :ticked}
    end
  end

  defp register_emitter do
    :ok =
      Discovery.register(
        ToolAd.new(%{
          id: "t.emitter",
          coordinate: "function.test.emitter",
          kinds: [:compute],
          binding: {:module, Emitter},
          operational: %{actions: %{}},
          constraint: %{idempotency: %{}, blast_radius: %{}},
          affordance: %{declared: [], learned: [], open: false},
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
  end

  @tag opts: [
         policy: %Policy{allow: ["function.test.*"], fidelity_min: :authoritative},
         hop_limit: 8
       ]
  test "a loop through an emitting tool stops at the hop limit", %{rt: rt} do
    register_emitter()
    await(fn -> "FUNCTION_TEST_EMITTER" in Anemos.Runtime.describe(rt).modules end)
    :ok = Anemos.Runtime.load(rt, ~s|rule r { when LOOP_TICK { [FUNCTION_TEST_EMITTER::tick] } }|)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Events.emit(:tick, "loop.tick", %{}, :seed)
        Process.sleep(500)
      end)

    ticks = Enum.count(Anemos.Runtime.trace(rt, 200), &(&1.event == "LOOP_TICK"))
    assert ticks == 8
    assert log =~ "chain of cause and effect"
  end

  test "any payload shape is taken", %{rt: rt} do
    :ok = Anemos.Runtime.load(rt, ~s|rule r { when ODD_SHAPE { log ?topic } }|)
    events = Process.whereis(:"#{rt}.llmagent.events")

    Events.emit(:x, "odd.shape", %URI{path: "/"}, :test)
    Events.emit({:tuple, :type}, "odd.shape", %{{:a, 1} => 2}, {:pid, self()})
    Events.emit(:x, "odd.shape", [1, 2], :test)
    await(fn -> Enum.count(Anemos.Runtime.trace(rt, 200), &(&1.event == "ODD_SHAPE")) == 3 end)

    assert Process.whereis(:"#{rt}.llmagent.events") == events
  end

  @tag opts: [dispatch_timeout_ms: 100]
  test "a runtime that does not answer in time is logged, and the next event still goes", %{
    rt: rt
  } do
    :ok =
      Anemos.Runtime.load(
        rt,
        ~s|rule r { when SLOW_ONE { log "one" } when NEXT_ONE { log "two" } }|
      )

    events = Process.whereis(:"#{rt}.llmagent.events")
    dispatcher = Process.whereis(:"#{rt}.dispatcher")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        :sys.suspend(dispatcher)
        Events.emit(:x, "slow.one", %{}, :test)
        Process.sleep(300)
        :sys.resume(dispatcher)
        Events.emit(:x, "next.one", %{}, :test)
        await(fn -> "NEXT_ONE" in fired(rt) end)
      end)

    assert log =~ "did not answer SLOW_ONE within 100ms"
    assert Process.whereis(:"#{rt}.llmagent.events") == events
  end

  test "another runtime's emits are events here; this runtime's own are not", %{rt: rt} do
    other = :"#{rt}_other"
    start_supervised!(Supervisor.child_spec({Anemos.Runtime, name: other}, id: :other_rt))

    start_supervised!(
      Supervisor.child_spec({LLMAgent.Anemos, runtime: other, policy: %Policy{}}, id: :other_att)
    )

    source = """
    rule say { when EV { emit [EVENT::hello] to channel(greeting) } }
    rule hear { when GREETING { log "heard" } }
    """

    :ok = Anemos.Runtime.load(rt, source)
    :ok = Anemos.Runtime.load(other, source)

    Anemos.Runtime.dispatch(other, "EV")
    await(fn -> "GREETING" in fired(rt) end)

    Process.sleep(50)
    refute "GREETING" in fired(other)
  end

  test "an event nothing listens for is not dispatched", %{rt: rt} do
    :ok = Anemos.Runtime.load(rt, ~s|rule r { when WANTED { log "w" } }|)
    Events.emit(:x, "unwanted", %{}, :test)
    Events.emit(:x, "wanted", %{}, :test)
    await(fn -> "WANTED" in fired(rt) end)
    refute "UNWANTED" in fired(rt)
  end

  test "EVENT and the connector come back after the runtime restarts", %{rt: rt} do
    EventBus.subscribe("after.restart")
    sup = Process.whereis(:"#{rt}.supervisor")
    ref = Process.monitor(sup)
    Process.exit(sup, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}

    # The test's own supervisor restarts the runtime; the attachment's tools
    # process notices and binds again.
    await(fn ->
      Process.whereis(:"#{rt}.dispatcher") != nil and
        "EVENT" in Anemos.Runtime.describe(rt).modules
    end)

    :ok =
      Anemos.Runtime.load(
        rt,
        ~s|rule r { when EV { emit [EVENT::back] to channel(after.restart) } }|
      )

    Anemos.Runtime.dispatch(rt, "EV")
    assert_receive {:event, "after.restart", %EventStruct{source: {LLMAgent.Anemos.Channel, ^rt}}}
  end

  @tag opts: [events: false, connect: false]
  test "both directions can be switched off", %{rt: rt} do
    assert Process.whereis(:"#{rt}.llmagent.events") == nil
    Events.emit(:x, "some.topic", %{}, :test)
    Process.sleep(50)
    refute "SOME_TOPIC" in fired(rt)
  end
end

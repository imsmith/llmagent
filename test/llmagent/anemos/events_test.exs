defmodule LLMAgent.Anemos.EventsTest do
  use ExUnit.Case, async: false

  alias Comn.Events.EventStruct
  alias LLMAgent.{EventBus, Events, ToolAd, Tool.Policy, Tools.Discovery}

  setup context do
    Discovery.reset!()
    rt = :"ae_#{:erlang.phash2(context.test)}"
    start_supervised!({Anemos.Runtime, name: rt})

    opts = [runtime: rt, policy: %Policy{}] ++ Map.get(context, :opts, [])
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
                      source: LLMAgent.Anemos.Channel,
                      data: %{
                        payload: %{"event" => "ip.addr.changed", "iface" => "eth0"},
                        rule: "r"
                      }
                    }}

    Process.sleep(50)
    refute "SYSTEM_CONFIG_NETWORK" in fired(rt)
  end

  test "an event the runtime cannot take does not stop the next one", %{rt: rt} do
    events = Process.whereis(:"#{rt}.llmagent.events")
    Process.exit(Process.whereis(:"#{rt}.dispatcher"), :kill)
    Events.emit(:x, "while.down", %{}, :test)
    Events.emit(:x, "after.down", %{}, :test)
    await(fn -> "AFTER_DOWN" in fired(rt) end)
    assert Process.whereis(:"#{rt}.llmagent.events") == events
  end

  @tag opts: [events: false, connect: false]
  test "both directions can be switched off", %{rt: rt} do
    assert Process.whereis(:"#{rt}.llmagent.events") == nil
    Events.emit(:x, "some.topic", %{}, :test)
    Process.sleep(50)
    refute "SOME_TOPIC" in fired(rt)
  end
end

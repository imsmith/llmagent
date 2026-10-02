defmodule LLMAgent.Tool.GenerateTurnDispatchTest do
  @moduledoc """
  A canonical turn through the whole dispatcher pipeline, against an ad shaped
  exactly like the ones `priv/discovery/avahi-llama.tcl` registers.
  """

  use ExUnit.Case, async: false

  alias LLMAgent.{ToolAd, ToolQuery, Turn}
  alias LLMAgent.Tool.{Dispatcher, Policy}
  alias LLMAgent.Tools.Discovery
  alias LLMAgent.WireFixtures

  @allow %Policy{allow: ["compute.llm.chat"], fidelity_min: :authoritative}

  setup do
    case Process.whereis(Discovery) do
      nil -> {:ok, _} = Discovery.start_link(consume_announcements: false)
      _ -> Discovery.reset!()
    end

    LLMAgent.Tool.Bindings.init_registry()
    LLMAgent.Tool.Kinds.init_registry()

    bypass = Bypass.open()
    {:ok, bypass: bypass, host: "http://localhost:#{bypass.port}"}
  end

  defp llama_ad(host, model, id \\ "llama.skynet-test.8080") do
    ToolAd.new(%{
      id: id,
      coordinate: "compute.llm.chat",
      kinds: [:generate],
      binding: {:openai_chat, %{api_host: host, model: model}},
      operational: %{actions: %{"chat" => %{concurrency: 4}}, model_id: model},
      constraint: %{idempotency: %{}, blast_radius: %{}},
      affordance: %{declared: [%{intent: :long_context, n_ctx: 32_768}], learned: [], open: true},
      fidelity: :authoritative,
      provenance: %{
        source: "mdns/_llama._tcp",
        produced_at: DateTime.utc_now(),
        based_on: [],
        signature: nil
      },
      lease: :permanent
    })
  end

  defp turn do
    %Turn{
      messages: [
        %{role: :user, content: [%{type: :text, text: "weather?", extra: %{}}], extra: %{}}
      ]
    }
  end

  defp collector do
    test = self()

    fn event ->
      send(test, {:event, event})
      :cont
    end
  end

  defp serve(bypass, fixture) do
    test = self()

    Bypass.expect_once(bypass, "POST", "/chat/completions", fn conn ->
      {:ok, request, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, Jason.decode!(request)})

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(200, WireFixtures.read(fixture))
    end)
  end

  # Fails the test if the performer is contacted at all.
  defp refuse_all(bypass) do
    Bypass.stub(bypass, "POST", "/chat/completions", fn conn ->
      flunk("the performer was contacted: #{conn.request_path}")
    end)
  end

  test "an allowing policy streams the turn and returns the folded message", ctx do
    :ok = Discovery.register(llama_ad(ctx.host, "m"))
    serve(ctx.bypass, "openai_tool_stream.sse")

    assert {:ok, message, provenance} =
             Dispatcher.generate("compute.llm.chat", "chat", %{turn: turn()},
               policy: @allow,
               into: collector()
             )

    assert %{type: :tool_call, name: "get_weather", input: %{"city" => "Paris"}} =
             List.last(message.content)

    assert provenance.stop_reason == :tool_use
    assert_received {:event, {:start, _}}
    assert_received {:event, {:stop, :tool_use, _}}
  end

  test "the default policy denies and the performer is never contacted", ctx do
    :ok = Discovery.register(llama_ad(ctx.host, "m"))
    refuse_all(ctx.bypass)

    assert {:error, :forbidden, :not_allowed} =
             Dispatcher.generate("compute.llm.chat", "chat", %{turn: turn()}, into: collector())

    refute_received {:event, _}
  end

  test "a policy naming another provenance source denies and the performer is never contacted",
       ctx do
    :ok = Discovery.register(llama_ad(ctx.host, "m"))
    refuse_all(ctx.bypass)
    policy = %{@allow | provenance: %{source: ["hub.config"], signed: false}}

    assert {:error, :forbidden, :provenance} =
             Dispatcher.generate("compute.llm.chat", "chat", %{turn: turn()},
               policy: policy,
               into: collector()
             )

    refute_received {:event, _}
  end

  test "a policy naming the ad's provenance source allows", ctx do
    :ok = Discovery.register(llama_ad(ctx.host, "m"))
    serve(ctx.bypass, "openai_text_stream.sse")
    policy = %{@allow | provenance: %{source: ["mdns/_llama._tcp"], signed: false}}

    assert {:ok, _message, %{stop_reason: :end_turn}} =
             Dispatcher.generate("compute.llm.chat", "chat", %{turn: turn()}, policy: policy)
  end

  test "an allowed call emits the generate telemetry event", ctx do
    :ok = Discovery.register(llama_ad(ctx.host, "m"))
    serve(ctx.bypass, "openai_text_stream.sse")
    parent = self()
    handler = "generate-turn-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:llmagent, :tool, :generate],
      fn _name, _measurements, metadata, _config -> send(parent, {:telemetry, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, _, _} =
             Dispatcher.generate("compute.llm.chat", "chat", %{turn: turn()}, policy: @allow)

    assert_receive {:telemetry, %{coordinate: "compute.llm.chat", action: "chat"}}, 500
  end

  # The mDNS shim derives an ad's id from host and port, and the port adapter
  # falls back from register/1 to update/1 on :duplicate_id. This is what a
  # host loading a different model looks like to the registry.
  test "a host that changes its model replaces its ad, and the next turn uses the new model",
       ctx do
    :ok = Discovery.register(llama_ad(ctx.host, "old-model"))

    assert {:error, :duplicate_id} = Discovery.register(llama_ad(ctx.host, "new-model"))
    assert :ok = Discovery.update(llama_ad(ctx.host, "new-model"))

    assert {:ok, [%ToolAd{binding: {:openai_chat, %{model: "new-model"}}}]} =
             Discovery.find_all(ToolQuery.new(%{coordinate: "compute.llm.chat"}))

    serve(ctx.bypass, "openai_text_stream.sse")

    assert {:ok, _, _} =
             Dispatcher.generate("compute.llm.chat", "chat", %{turn: turn()}, policy: @allow)

    assert_received {:request, %{"model" => "new-model"}}
  end
end

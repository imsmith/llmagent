# End-to-end probe for the turn-shaped generate path.
#
# Decodes a request captured from a real Claude Code client, dispatches it
# through LLMAgent.Tool.Dispatcher.generate to a live OpenAI-compatible
# performer, and writes the reply as the Anthropic SSE stream a Messages
# client would receive. Diagnostics go to stderr.
#
#   mix run scripts/hub_probe.exs --host http://10.10.1.226:8080 --model probe --out /tmp/hub_probe.sse
#   mix run scripts/hub_probe.exs            # waits for an mDNS-discovered ad
#
# Options:
#   --host URL       performer base URL; with --model, skips discovery
#   --model ID       model id to send to the performer
#   --fixture NAME   request under test/fixtures/wire/ (default claude_code_request.json)
#   --max-tokens N   cap the reply (default 256)
#   --out PATH       write the stream here instead of stdout, which mix and the
#                    logger also write to
#
# Exits non-zero on any error result.

defmodule HubProbe do
  @moduledoc false

  alias LLMAgent.Codec.Anthropic
  alias LLMAgent.{ToolAd, ToolQuery}
  alias LLMAgent.Tool.{Dispatcher, Policy}
  alias LLMAgent.Tools.Discovery

  @policy %Policy{allow: ["compute.llm.chat"], fidelity_min: :authoritative}

  def run(argv) do
    {opts, _rest} =
      OptionParser.parse!(argv, strict: [host: :string, model: :string, fixture: :string, max_tokens: :integer, out: :string])

    {:ok, _} = Application.ensure_all_started(:LLMAgent)

    ad = performer(opts)
    {:openai_chat, binding} = ad.binding
    note("performer: #{binding.api_host} model=#{binding.model} (ad #{ad.id})")

    fixture = Keyword.get(opts, :fixture, "claude_code_request.json")
    wire = "test/fixtures/wire" |> Path.join(fixture) |> File.read!() |> Jason.decode!()
    {:ok, turn} = Anthropic.decode_request(wire)
    turn = %{turn | params: Map.put(turn.params, :max_tokens, Keyword.get(opts, :max_tokens, 256))}
    note("turn: #{length(turn.messages)} messages, #{length(turn.tools)} tools, client model #{turn.model}")

    out =
      case opts[:out] do
        nil -> :stdio
        path -> File.open!(path, [:write, :binary])
      end

    # `into` is a plain event callback, so the encoder's state is held beside
    # it; a real ingress keeps it in its connection loop.
    {:ok, encoder} = Agent.start_link(fn -> Anthropic.stream_encoder(model: turn.model) end)

    into = fn event ->
      IO.binwrite(out, Agent.get_and_update(encoder, &Anthropic.encode_stream(&1, event)))
      :cont
    end

    case Dispatcher.generate(ad, "chat", %{turn: turn}, policy: @policy, into: into) do
      {:ok, message, provenance} ->
        kinds = Enum.map(message.content, & &1.type)
        note("ok: blocks=#{inspect(kinds)} provenance=#{inspect(provenance)}")

      error ->
        note("FAILED: #{inspect(error, limit: 20, printable_limit: 600)}")
        System.halt(1)
    end
  end

  defp performer(opts) do
    case {opts[:host], opts[:model]} do
      {host, model} when is_binary(host) and is_binary(model) ->
        ToolAd.new(%{
          id: "probe.#{System.unique_integer([:positive])}",
          coordinate: "compute.llm.chat",
          kinds: [:generate],
          binding: {:openai_chat, %{api_host: host, model: model}},
          operational: %{actions: %{"chat" => %{}}},
          constraint: %{idempotency: %{}, blast_radius: %{}},
          affordance: %{declared: [], learned: [], open: true},
          fidelity: :authoritative,
          provenance: %{source: "probe", produced_at: DateTime.utc_now(), based_on: [], signature: nil},
          lease: :permanent
        })

      _ ->
        discover(System.monotonic_time(:millisecond) + 15_000)
    end
  end

  defp discover(deadline) do
    case Discovery.find_all(ToolQuery.new(%{coordinate: "compute.llm.chat"})) do
      {:ok, [ad | _]} ->
        ad

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(250)
          discover(deadline)
        else
          note("FAILED: no compute.llm.chat ad discovered within 15s; pass --host and --model")
          System.halt(1)
        end
    end
  end

  defp note(line), do: IO.puts(:stderr, line)
end

HubProbe.run(System.argv())

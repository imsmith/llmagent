defmodule LLMAgent.Codec.AnthropicTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias LLMAgent.Codec.{Anthropic, OpenAI, SSE}
  alias LLMAgent.Turn
  alias LLMAgent.Turn.Fold
  alias LLMAgent.WireFixtures

  @canonical_keys ~w(model system messages tools tool_choice stream max_tokens temperature top_p stop_sequences)

  defp frames(raw) do
    {frames, _state} = SSE.feed(SSE.new(), raw)
    Enum.map(frames, fn frame -> {frame.event, Jason.decode!(frame.data)} end)
  end

  defp openai_events(name) do
    {events, state} = OpenAI.decode_stream(OpenAI.stream_decoder(), WireFixtures.read(name))
    events ++ OpenAI.finish_stream(state)
  end

  defp encode(events, opts \\ [model: "client-model", id: "msg_test"]) do
    {iodata, _state} =
      Enum.reduce(events, {[], Anthropic.stream_encoder(opts)}, fn event, {acc, state} ->
        {out, state} = Anthropic.encode_stream(state, event)
        {[acc, out], state}
      end)

    frames(IO.iodata_to_binary(iodata))
  end

  defp block_types(frames),
    do: for({"content_block_start", json} <- frames, do: json["content_block"]["type"])

  defp stop_reason(frames),
    do:
      Enum.find_value(frames, fn {event, json} ->
        event == "message_delta" && json["delta"]["stop_reason"]
      end)

  describe "decode_request/1 on a real Claude Code request" do
    setup do
      wire = WireFixtures.json("claude_code_request.json")
      {:ok, turn} = Anthropic.decode_request(wire)
      {:ok, wire: wire, turn: turn}
    end

    test "carries model, stream and tools", %{wire: wire, turn: turn} do
      assert %Turn{} = turn
      assert turn.model == wire["model"]
      assert turn.stream == true
      assert length(turn.tools) == length(wire["tools"])
      assert turn.params.max_tokens == wire["max_tokens"]
    end

    test "keeps every unknown top-level field in extra", %{wire: wire, turn: turn} do
      assert Map.keys(turn.extra) |> Enum.sort() ==
               (Map.keys(wire) -- @canonical_keys) |> Enum.sort()

      assert turn.extra != %{}
    end

    test "keeps cache_control on the system blocks that had it", %{wire: wire, turn: turn} do
      assert length(turn.system) == length(wire["system"])

      for {wire_block, block} <- Enum.zip(wire["system"], turn.system) do
        assert block.type == :text
        assert block.extra["cache_control"] == wire_block["cache_control"]
      end

      assert Enum.any?(turn.system, &Map.has_key?(&1.extra, "cache_control"))
    end

    test "keeps defer_loading on the tools that had it", %{wire: wire, turn: turn} do
      for {wire_tool, tool} <- Enum.zip(wire["tools"], turn.tools) do
        assert tool.name == wire_tool["name"]
        assert tool.input_schema == wire_tool["input_schema"]
        assert tool.extra["defer_loading"] == wire_tool["defer_loading"]
      end

      assert Enum.any?(wire["tools"], &Map.has_key?(&1, "defer_loading"))
    end

    test "keeps a mid-conversation system message and its unknown fields", %{
      wire: wire,
      turn: turn
    } do
      assert Enum.map(turn.messages, & &1.role) ==
               Enum.map(wire["messages"], &String.to_existing_atom(&1["role"]))

      assert :system in Enum.map(turn.messages, & &1.role)

      for {wire_message, message} <- Enum.zip(wire["messages"], turn.messages) do
        assert Map.keys(message.extra) |> Enum.sort() ==
                 (Map.keys(wire_message) -- ~w(role content)) |> Enum.sort()
      end
    end
  end

  describe "decode_request/1 on a real follow-up request" do
    setup do
      wire = WireFixtures.json("claude_code_followup_request.json")
      {:ok, turn} = Anthropic.decode_request(wire)
      {:ok, wire: wire, turn: turn}
    end

    test "decodes the assistant's reasoning and tool call, then the user's tool result", %{
      wire: wire,
      turn: turn
    } do
      index = Enum.find_index(turn.messages, &(&1.role == :assistant))
      assistant = Enum.at(turn.messages, index)
      user = Enum.at(turn.messages, index + 1)

      wire_call =
        wire["messages"]
        |> Enum.at(index)
        |> Map.fetch!("content")
        |> Enum.find(&(&1["type"] == "tool_use"))

      assert [%{type: :reasoning} = reasoning, %{type: :tool_call} = call] = assistant.content
      assert Map.has_key?(reasoning.extra, "signature")
      assert call.id == wire_call["id"]
      assert call.name == wire_call["name"]
      assert call.input == wire_call["input"]
      assert Map.has_key?(call.extra, "cache_control")

      assert user.role == :user
      assert [%{type: :tool_result} = result] = user.content
      assert result.tool_call_id == call.id
      assert result.is_error == true
      assert [%{type: :text}] = result.content
    end

    test "decodes a system message whose content was a bare string", %{wire: wire, turn: turn} do
      index =
        Enum.find_index(wire["messages"], &(&1["role"] == "system" and is_binary(&1["content"])))

      assert index != nil

      assert %{role: :system, content: [%{type: :text, text: text}]} =
               Enum.at(turn.messages, index)

      assert text == Enum.at(wire["messages"], index)["content"]
    end
  end

  describe "decode_request/1 on hostile input" do
    setup do
      {:ok, wire: WireFixtures.json("claude_code_followup_request.json")}
    end

    test "refuses an unknown content block type", %{wire: wire} do
      bad = %{
        "role" => "assistant",
        "content" => [%{"type" => "server_tool_use", "id" => "x", "name" => "web_search"}]
      }

      wire = Map.update!(wire, "messages", &(&1 ++ [bad]))

      assert {:error, {:unsupported, message}} = Anthropic.decode_request(wire)
      assert message =~ "server_tool_use"
    end

    test "refuses a vendor server-side tool", %{wire: wire} do
      wire =
        Map.update!(
          wire,
          "tools",
          &[%{"type" => "web_search_20250305", "name" => "web_search"} | &1]
        )

      assert {:error, {:unsupported, message}} = Anthropic.decode_request(wire)
      assert message =~ "web_search_20250305"
    end

    test "refuses an unknown role", %{wire: wire} do
      wire = Map.update!(wire, "messages", &(&1 ++ [%{"role" => "tool", "content" => "x"}]))
      assert {:error, {:unsupported, message}} = Anthropic.decode_request(wire)
      assert message =~ "tool"
    end

    test "still refuses an unknown top-level block such as a document", %{wire: wire} do
      bad = %{"role" => "user", "content" => [%{"type" => "document", "source" => %{}}]}
      wire = Map.update!(wire, "messages", &(&1 ++ [bad]))

      assert {:error, {:unsupported, message}} = Anthropic.decode_request(wire)
      assert message =~ "document"
    end

    test "a known block missing a required field is invalid, not unsupported", %{wire: wire} do
      for block <- [
            %{"type" => "tool_use", "name" => "f"},
            %{"type" => "text"},
            %{"type" => "tool_result"}
          ] do
        wire = Map.update!(wire, "messages", &(&1 ++ [%{"role" => "user", "content" => [block]}]))
        assert {:error, {:invalid, _}} = Anthropic.decode_request(wire), inspect(block)
      end
    end

    test "an image whose source is not an object is invalid, never a raise", %{wire: wire} do
      bad = %{"role" => "user", "content" => [%{"type" => "image", "source" => "oops"}]}
      wire = Map.update!(wire, "messages", &(&1 ++ [bad]))

      assert {:error, {:invalid, _}} = Anthropic.decode_request(wire)
    end

    test "a model that is not a string is invalid", %{wire: wire} do
      for bad <- [%{"a" => 1}, ["x"], 7, true] do
        assert {:error, {:invalid, message}} =
                 Anthropic.decode_request(Map.put(wire, "model", bad)),
               inspect(bad)

        assert message =~ "model"
      end

      assert {:ok, %{model: nil}} = Anthropic.decode_request(Map.delete(wire, "model"))
    end

    test "refuses messages that are missing or not a list", %{wire: wire} do
      assert {:error, {:invalid, _}} = Anthropic.decode_request(Map.delete(wire, "messages"))

      assert {:error, {:invalid, _}} =
               Anthropic.decode_request(Map.put(wire, "messages", "not-a-list"))
    end

    test "does not mint atoms from wire strings", %{wire: wire} do
      role = "role_#{System.unique_integer([:positive])}"
      wire = Map.update!(wire, "messages", &(&1 ++ [%{"role" => role, "content" => "x"}]))

      assert {:error, {:unsupported, _}} = Anthropic.decode_request(wire)
      assert_raise ArgumentError, fn -> String.to_existing_atom(role) end
    end
  end

  describe "decode_request/1 on blocks a long-lived session accumulates" do
    setup do
      {:ok, wire: WireFixtures.json("claude_code_followup_request.json")}
    end

    test "redacted thinking is carried as reasoning and never reaches an OpenAI performer", %{
      wire: wire
    } do
      redacted = %{
        "role" => "assistant",
        "content" => [
          %{"type" => "redacted_thinking", "data" => "opaque"},
          %{"type" => "text", "text" => "hi"}
        ]
      }

      wire = Map.update!(wire, "messages", &(&1 ++ [redacted]))

      assert {:ok, turn} = Anthropic.decode_request(wire)

      assert [%{type: :reasoning, text: "", extra: extra}, %{type: :text}] =
               List.last(turn.messages).content

      assert extra["redacted_thinking"]["data"] == "opaque"

      refute turn |> OpenAI.encode_request("m") |> Jason.encode!() =~ "opaque"
    end

    test "an unknown block inside a tool result degrades to a text marker", %{wire: wire} do
      result = %{
        "role" => "user",
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => "t1",
            "content" => [
              %{"type" => "tool_reference", "tool_name" => "Bash"},
              %{"type" => "text", "text" => "found"}
            ]
          }
        ]
      }

      wire = Map.update!(wire, "messages", &(&1 ++ [result]))

      assert {:ok, turn} = Anthropic.decode_request(wire)

      assert [%{type: :tool_result, content: [marker, %{type: :text, text: "found"}]}] =
               List.last(turn.messages).content

      assert %{type: :text, text: text, extra: %{"omitted" => %{"type" => "tool_reference"}}} =
               marker

      assert text =~ "tool_reference"
    end
  end

  describe "a real turn re-encoded for an OpenAI performer" do
    for name <- ~w(claude_code_request.json claude_code_followup_request.json) do
      test "#{name} is portable" do
        {:ok, turn} = unquote(name) |> WireFixtures.json() |> Anthropic.decode_request()
        json = turn |> OpenAI.encode_request("performer-model") |> Jason.encode!()
        body = Jason.decode!(json)
        roles = Enum.map(body["messages"], & &1["role"])

        assert body["model"] == "performer-model"
        assert hd(roles) == "system"
        assert Enum.count(roles, &(&1 == "system")) == 1

        for [a, b] <- Enum.chunk_every(roles, 2, 1, :discard), a in ["user", "assistant"] do
          assert a != b, "adjacent #{a} messages in #{inspect(roles)}"
        end

        assert %{"stream" => true, "stream_options" => %{"include_usage" => true}} = body
        assert length(body["tools"]) == length(turn.tools)

        for key <- ~w(cache_control signature defer_loading context_management) do
          refute json =~ ~s("#{key}":), key
        end
      end
    end

    test "the follow-up pairs the assistant's tool call with a tool message" do
      {:ok, turn} =
        "claude_code_followup_request.json" |> WireFixtures.json() |> Anthropic.decode_request()

      messages = OpenAI.encode_request(turn, "performer-model")["messages"]
      index = Enum.find_index(messages, &(&1["role"] == "assistant"))

      assert %{"tool_calls" => [%{"id" => id}]} = Enum.at(messages, index)
      assert %{"role" => "tool", "tool_call_id" => ^id} = Enum.at(messages, index + 1)
    end
  end

  describe "encode_stream/2" do
    @pairs [
      {"openai_text_stream.sse", "anthropic_text_stream.sse"},
      {"openai_tool_stream.sse", "anthropic_tool_stream.sse"},
      {"openai_two_tools_stream.sse", "anthropic_two_tools_stream.sse"}
    ]

    test "has the same block types and stop reason as the stream the server itself produced" do
      for {source, reference} <- @pairs do
        encoded = source |> openai_events() |> encode()
        recorded = reference |> WireFixtures.read() |> frames()

        assert block_types(encoded) == block_types(recorded), source
        assert stop_reason(encoded) == stop_reason(recorded), source
      end
    end

    test "is well-formed: framing, ordering and block indices" do
      for {source, _reference} <- @pairs do
        encoded = source |> openai_events() |> encode()

        assert {"message_start", _} = hd(encoded)
        assert [{"message_delta", _}, {"message_stop", _}] = Enum.take(encoded, -2)

        for {event, json} <- encoded, do: assert(json["type"] == event)

        starts = for {"content_block_start", json} <- encoded, do: json["index"]
        stops = for {"content_block_stop", json} <- encoded, do: json["index"]
        assert starts == Enum.to_list(0..(length(starts) - 1))
        assert stops == starts
      end
    end

    test "text survives" do
      encoded = "openai_text_stream.sse" |> openai_events() |> encode()

      text =
        for {"content_block_delta", %{"delta" => %{"type" => "text_delta", "text" => text}}} <-
              encoded,
            into: "",
            do: text

      assert text == "hello there"
    end

    test "tool arguments survive, per block" do
      encoded = "openai_two_tools_stream.sse" |> openai_events() |> encode()

      inputs =
        encoded
        |> Enum.flat_map(fn
          {"content_block_delta",
           %{"index" => index, "delta" => %{"type" => "input_json_delta", "partial_json" => json}}} ->
            [{index, json}]

          _ ->
            []
        end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Enum.sort()
        |> Enum.map(fn {_index, parts} -> parts |> Enum.join() |> Jason.decode!() end)

      assert inputs == [%{"city" => "Paris"}, %{"city" => "Oslo"}]

      assert [%{"name" => "get_weather", "input" => %{}}, %{"name" => "get_weather"}] =
               for(
                 {"content_block_start", %{"content_block" => %{"type" => "tool_use"} = block}} <-
                   encoded,
                 do: block
               )
    end

    test "echoes the client's model and the given id, not the performer's" do
      [{"message_start", json} | _] =
        "openai_text_stream.sse" |> openai_events() |> encode(model: "claude-x", id: "msg_1")

      assert json["message"]["model"] == "claude-x"
      assert json["message"]["id"] == "msg_1"
      assert json["message"]["role"] == "assistant"
      assert json["message"]["content"] == []
    end

    test "reports usage as integers, with unknown counts as zero" do
      encoded =
        encode([
          {:start, %{model: "m"}},
          {:stop, :end_turn, %{input_tokens: nil, output_tokens: nil}}
        ])

      assert {"message_delta", %{"usage" => %{"input_tokens" => 0, "output_tokens" => 0}}} =
               Enum.at(encoded, -2)

      encoded = "openai_text_stream.sse" |> openai_events() |> encode()

      assert {"message_delta",
              %{"usage" => %{"input_tokens" => input, "output_tokens" => output}}} =
               Enum.at(encoded, -2)

      assert input > 0 and output > 0
    end

    test "an error event produces an error frame and nothing after it" do
      events = [
        {:start, %{model: "m"}},
        {:block_start, 0, :text},
        {:error, :incomplete_stream},
        {:block_stop, 0}
      ]

      encoded = encode(events)

      assert {"error", %{"error" => %{"type" => "api_error", "message" => message}}} =
               List.last(encoded)

      assert is_binary(message)
      assert Enum.count(encoded, fn {event, _} -> event == "error" end) == 1
    end

    test "generates a message id when none is given" do
      [{"message_start", json} | _] = encode([{:start, %{model: "m"}}], model: "claude-x")
      assert "msg_" <> rest = json["message"]["id"]
      assert byte_size(rest) > 8
    end
  end

  describe "encode_response/2" do
    test "a folded two-tool turn becomes a message with tool_use blocks" do
      {:ok, result} =
        "openai_two_tools_stream.sse"
        |> openai_events()
        |> Enum.reduce(Fold.new(), &Fold.step(&2, &1))
        |> Fold.result()

      body =
        result
        |> Anthropic.encode_response(model: "claude-x", id: "msg_1")
        |> Jason.encode!()
        |> Jason.decode!()

      assert %{"type" => "message", "role" => "assistant", "model" => "claude-x", "id" => "msg_1"} =
               body

      assert body["stop_reason"] == "tool_use"

      assert is_integer(body["usage"]["input_tokens"]) and
               is_integer(body["usage"]["output_tokens"])

      assert [%{"input" => %{"city" => "Paris"}}, %{"input" => %{"city" => "Oslo"}}] =
               Enum.filter(body["content"], &(&1["type"] == "tool_use"))

      assert hd(body["content"])["type"] == "thinking"
    end
  end

  describe "encode_error/2" do
    test "maps the status to Anthropic's error type" do
      expected = %{
        400 => "invalid_request_error",
        401 => "authentication_error",
        403 => "permission_error",
        404 => "not_found_error",
        429 => "rate_limit_error",
        502 => "api_error"
      }

      for {status, type} <- expected do
        assert %{"type" => "error", "error" => %{"type" => ^type, "message" => "nope"}} =
                 Anthropic.encode_error(status, "nope")
      end
    end
  end
end

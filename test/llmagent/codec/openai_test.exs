defmodule LLMAgent.Codec.OpenAITest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias LLMAgent.Codec.OpenAI
  alias LLMAgent.Turn
  alias LLMAgent.Turn.Fold
  alias LLMAgent.WireFixtures

  @streams ~w(openai_text_stream.sse openai_tool_stream.sse openai_two_tools_stream.sse openai_max_tokens_stream.sse)

  defp decode(chunks) do
    {events, state} =
      Enum.reduce(chunks, {[], OpenAI.stream_decoder()}, fn chunk, {acc, state} ->
        {events, state} = OpenAI.decode_stream(state, chunk)
        {acc ++ events, state}
      end)

    events ++ OpenAI.finish_stream(state)
  end

  defp fold(events), do: events |> Enum.reduce(Fold.new(), &Fold.step(&2, &1)) |> Fold.result()

  defp recorded_usage(name) do
    name
    |> WireFixtures.read()
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: {"))
    |> Enum.map(&(&1 |> String.replace_prefix("data: ", "") |> Jason.decode!()))
    |> Enum.find_value(& &1["usage"])
  end

  describe "decode_stream/2" do
    test "a text reply folds to reasoning then the exact text" do
      name = "openai_text_stream.sse"
      assert {:ok, result} = name |> WireFixtures.read() |> List.wrap() |> decode() |> fold()

      assert [%{type: :reasoning}, %{type: :text, text: "hello there"}] = result.message.content
      assert result.stop_reason == :end_turn

      usage = recorded_usage(name)

      assert result.usage == %{
               input_tokens: usage["prompt_tokens"],
               output_tokens: usage["completion_tokens"]
             }

      assert is_binary(result.model)
    end

    test "a single tool call folds to reasoning then the call" do
      assert {:ok, result} =
               "openai_tool_stream.sse"
               |> WireFixtures.read()
               |> List.wrap()
               |> decode()
               |> fold()

      assert [
               %{type: :reasoning},
               %{type: :tool_call, name: "get_weather", input: %{"city" => "Paris"}}
             ] =
               result.message.content

      assert result.stop_reason == :tool_use
    end

    test "two tool calls get distinct ids and canonical indices 1 and 2" do
      events = decode([WireFixtures.read("openai_two_tools_stream.sse")])

      assert [
               {0, :reasoning},
               {1, {:tool_call, id_a, "get_weather"}},
               {2, {:tool_call, id_b, "get_weather"}}
             ] =
               for({:block_start, index, kind} <- events, do: {index, kind})

      assert id_a != id_b

      assert {:ok, %{message: %{content: [_, a, b]}}} = fold(events)
      assert a.input == %{"city" => "Paris"}
      assert b.input == %{"city" => "Oslo"}
    end

    test "truncation by max_tokens is reported as :max_tokens" do
      assert {:ok, %{stop_reason: :max_tokens}} =
               "openai_max_tokens_stream.sse"
               |> WireFixtures.read()
               |> List.wrap()
               |> decode()
               |> fold()
    end

    test "feeding one byte at a time gives the same events as feeding whole" do
      for name <- @streams do
        raw = WireFixtures.read(name)
        assert decode(WireFixtures.bytes(raw)) == decode([raw]), name
      end
    end

    test "every block is stopped before the next starts and deltas hit the open block" do
      for name <- @streams do
        events = decode([WireFixtures.read(name)])

        final =
          Enum.reduce(events, nil, fn
            {:block_start, index, _kind}, open ->
              assert open == nil,
                     "#{name}: block #{index} started while #{inspect(open)} was open"

              index

            {:block_stop, index}, open ->
              assert open == index, name
              nil

            {delta, index, _data}, open
            when delta in [:text_delta, :reasoning_delta, :tool_args_delta] ->
              assert open == index, name
              open

            _other, open ->
              open
          end)

        assert final == nil, name
        assert match?({:start, _}, hd(events)), name
        assert match?({:stop, _, _}, List.last(events)), name
      end
    end

    test "a stream that dies mid-way closes the open block and ends in an error" do
      raw = WireFixtures.read("openai_tool_stream.sse")
      events = decode([binary_part(raw, 0, div(byte_size(raw), 2))])

      assert List.last(events) == {:error, :incomplete_stream}

      starts = for {:block_start, index, _} <- events, do: index
      stops = for {:block_stop, index} <- events, do: index
      assert starts != []
      assert starts == stops

      assert {:error, :incomplete_stream} = fold(events)
    end

    test "finish_stream/1 after a complete stream adds nothing" do
      {_events, state} =
        OpenAI.decode_stream(OpenAI.stream_decoder(), WireFixtures.read("openai_text_stream.sse"))

      assert OpenAI.finish_stream(state) == []
    end
  end

  describe "decode_stream/2 on a broken or hostile performer" do
    defp sse(chunks), do: Enum.map_join(chunks, &("data: " <> Jason.encode!(&1) <> "\n\n"))

    defp chunk(delta, finish \\ nil),
      do: %{
        "model" => "m",
        "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish}]
      }

    defp tool(index, id, name, args),
      do: %{
        "tool_calls" => [
          %{"index" => index, "id" => id, "function" => %{"name" => name, "arguments" => args}}
        ]
      }

    defp more_args(index, args),
      do: %{"tool_calls" => [%{"index" => index, "function" => %{"arguments" => args}}]}

    defp no_delta_on_a_closed_block(events) do
      Enum.reduce(events, nil, fn
        {:block_start, index, _}, _open ->
          index

        {:block_stop, _index}, _open ->
          nil

        {tag, index, _}, open when tag in [:text_delta, :reasoning_delta, :tool_args_delta] ->
          assert index == open, "delta for block #{index} while #{inspect(open)} was open"
          open

        _other, open ->
          open
      end)
    end

    test "arguments for a tool call that was already closed by another tool call are an error" do
      events =
        decode([
          sse([
            chunk(tool(0, "a", "f", "{")),
            chunk(tool(1, "b", "g", "{}")),
            chunk(more_args(0, "}"))
          ])
        ])

      no_delta_on_a_closed_block(events)
      assert {:error, {:out_of_order_tool_call, 0}} in events
      assert {:error, {:out_of_order_tool_call, 0}} = fold(events)
    end

    test "arguments for a tool call that was already closed by text are an error" do
      events =
        decode([
          sse([
            chunk(tool(0, "a", "f", "{")),
            chunk(%{"content" => "hi"}),
            chunk(more_args(0, "}"))
          ])
        ])

      no_delta_on_a_closed_block(events)
      assert {:error, {:out_of_order_tool_call, 0}} in events
    end

    test "a chunk of the wrong shape is a bad frame, never a raise" do
      hostile = [
        %{"choices" => %{}},
        %{"choices" => ["x"]},
        chunk("a string"),
        chunk(%{"tool_calls" => %{}}),
        chunk(%{"tool_calls" => ["x"]}),
        chunk(%{"tool_calls" => [%{"index" => %{}, "function" => %{"arguments" => "{"}}]}),
        chunk(%{"tool_calls" => [%{"index" => 0, "id" => 7, "function" => %{"name" => 9}}]}),
        chunk(%{"tool_calls" => [%{"index" => 0, "id" => "a", "function" => "x"}]}),
        chunk(%{"content" => 5}),
        %{"choices" => [%{"delta" => %{}, "finish_reason" => 5}]},
        %{"choices" => [], "usage" => "lots"}
      ]

      for bad <- hostile do
        events = decode([sse([chunk(%{"content" => "ok"}), bad])])
        assert {:error, {:bad_frame, _}} = List.last(events), inspect(bad)
        no_delta_on_a_closed_block(events)
      end
    end

    test "a null error field is not an error" do
      ok = Map.put(chunk(%{"content" => "hi"}), "error", nil)
      events = decode([sse([ok, chunk(%{}, "stop")]) <> "data: [DONE]\n\n"])

      assert {:ok, %{message: %{content: [%{type: :text, text: "hi"}]}}} = fold(events)
    end
  end

  describe "decode_response/1" do
    test "a non-streaming reply folds to the same blocks as the stream" do
      body = WireFixtures.json("openai_two_tools.json")
      assert {:ok, result} = body |> OpenAI.decode_response() |> fold()

      assert [%{type: :reasoning}, a, b] = result.message.content
      assert %{type: :tool_call, name: "get_weather", input: %{"city" => "Paris"}} = a
      assert %{type: :tool_call, name: "get_weather", input: %{"city" => "Oslo"}} = b
      assert result.stop_reason == :tool_use

      assert result.usage == %{
               input_tokens: body["usage"]["prompt_tokens"],
               output_tokens: body["usage"]["completion_tokens"]
             }
    end
  end

  describe "encode_request/2" do
    defp text(string), do: %{type: :text, text: string, extra: %{}}

    defp turn do
      %Turn{
        model: "client-model",
        system: [text("be brief")],
        messages: [
          %{role: :user, content: [text("weather in Paris?")], extra: %{}},
          %{role: :system, content: [text("reminder")], extra: %{}},
          %{
            role: :assistant,
            content: [
              %{type: :reasoning, text: "thinking", extra: %{signature: "sig"}},
              %{
                type: :tool_call,
                id: "call_1",
                name: "get_weather",
                input: %{"city" => "Paris"},
                input_json: ~s({"city":"Paris"}),
                extra: %{"cache_control" => %{"type" => "ephemeral"}}
              }
            ],
            extra: %{}
          },
          %{
            role: :user,
            content: [
              %{
                type: :tool_result,
                tool_call_id: "call_1",
                content: [text("sunny")],
                is_error: false,
                extra: %{}
              },
              text("thanks")
            ],
            extra: %{}
          },
          %{role: :system, content: [text("another reminder")], extra: %{}}
        ],
        tools: [
          %{
            name: "get_weather",
            description: "Get weather",
            input_schema: %{"type" => "object"},
            extra: %{"defer_loading" => true}
          }
        ],
        tool_choice: :auto,
        params: %{max_tokens: 100, temperature: 0.5},
        stream: true,
        extra: %{"thinking" => %{"type" => "adaptive"}}
      }
    end

    defp encode(turn),
      do: turn |> OpenAI.encode_request("performer-model") |> Jason.encode!() |> Jason.decode!()

    test "uses the performer's model, not the client's" do
      assert encode(turn())["model"] == "performer-model"
    end

    test "has exactly one system message, first" do
      roles = Enum.map(encode(turn())["messages"], & &1["role"])
      assert hd(roles) == "system"
      assert Enum.count(roles, &(&1 == "system")) == 1
    end

    test "mid-conversation system messages become user text and same-role neighbours merge" do
      messages = encode(turn())["messages"]
      roles = Enum.map(messages, & &1["role"])

      assert roles == ["system", "user", "assistant", "tool", "user"]

      assert Enum.at(messages, 1)["content"] =~ "weather in Paris?"
      assert Enum.at(messages, 1)["content"] =~ "reminder"
      assert List.last(messages)["content"] =~ "thanks"
      assert List.last(messages)["content"] =~ "another reminder"
    end

    test "a tool call and its result become assistant tool_calls then a tool message" do
      messages = encode(turn())["messages"]
      assistant = Enum.find(messages, &(&1["role"] == "assistant"))
      tool = Enum.find(messages, &(&1["role"] == "tool"))

      assert [%{"id" => "call_1", "type" => "function", "function" => function}] =
               assistant["tool_calls"]

      assert function["name"] == "get_weather"
      assert Jason.decode!(function["arguments"]) == %{"city" => "Paris"}

      assert tool["tool_call_id"] == "call_1"
      assert tool["content"] == "sunny"
    end

    test "tools, tool_choice and params are carried" do
      body = encode(turn())

      assert [
               %{
                 "type" => "function",
                 "function" => %{"name" => "get_weather", "parameters" => %{"type" => "object"}}
               }
             ] =
               body["tools"]

      assert body["tool_choice"] == "auto"
      assert body["max_tokens"] == 100
      assert body["temperature"] == 0.5
    end

    test "streaming asks for usage; non-streaming does not" do
      assert %{"stream" => true, "stream_options" => %{"include_usage" => true}} = encode(turn())

      body = encode(%{turn() | stream: false})
      assert body["stream"] == false
      refute Map.has_key?(body, "stream_options")
    end

    test "nothing protocol-specific from another vendor leaks through" do
      json = turn() |> OpenAI.encode_request("performer-model") |> Jason.encode!()

      for key <- ~w(cache_control signature defer_loading thinking) do
        refute json =~ ~s("#{key}"), key
      end
    end

    test "a turn with no tools and no system omits those keys" do
      body = encode(%Turn{messages: [%{role: :user, content: [text("hi")], extra: %{}}]})

      assert body["messages"] == [%{"role" => "user", "content" => "hi"}]
      refute Map.has_key?(body, "tools")
      refute Map.has_key?(body, "tool_choice")
    end

    test "a system message between a tool call and its result does not separate them" do
      call = %{type: :tool_call, id: "c1", name: "f", input: %{}, input_json: "{}", extra: %{}}

      result = %{
        type: :tool_result,
        tool_call_id: "c1",
        content: [text("done")],
        is_error: false,
        extra: %{}
      }

      turn = %Turn{
        messages: [
          %{role: :user, content: [text("go")], extra: %{}},
          %{role: :assistant, content: [call], extra: %{}},
          %{role: :system, content: [text("reminder")], extra: %{}},
          %{role: :user, content: [result], extra: %{}}
        ]
      }

      messages = encode(turn)["messages"]
      assert Enum.map(messages, & &1["role"]) == ["user", "assistant", "tool", "user"]
      assert List.last(messages)["content"] == "reminder"
    end

    test "an image in a tool result reaches the performer instead of vanishing" do
      call = %{type: :tool_call, id: "c1", name: "read", input: %{}, input_json: "{}", extra: %{}}
      image = %{type: :image, media_type: "image/png", data: "AAAA", extra: %{}}

      result = %{
        type: :tool_result,
        tool_call_id: "c1",
        content: [image],
        is_error: false,
        extra: %{}
      }

      turn = %Turn{
        messages: [
          %{role: :assistant, content: [call], extra: %{}},
          %{role: :user, content: [result], extra: %{}}
        ]
      }

      assert [_assistant, tool, user] = encode(turn)["messages"]
      assert tool["role"] == "tool"
      assert tool["content"] != ""
      assert user["role"] == "user"

      assert Enum.any?(
               user["content"],
               &(&1["type"] == "image_url" and
                   &1["image_url"]["url"] == "data:image/png;base64,AAAA")
             )
    end

    test "an image becomes an image_url part with a data URL" do
      image = %{type: :image, media_type: "image/png", data: "AAAA", extra: %{}}
      body = encode(%Turn{messages: [%{role: :user, content: [text("look"), image], extra: %{}}]})

      assert [
               %{
                 "content" => [
                   %{"type" => "text", "text" => "look"},
                   %{"type" => "image_url", "image_url" => url}
                 ]
               }
             ] =
               body["messages"]

      assert url["url"] == "data:image/png;base64,AAAA"
    end
  end
end

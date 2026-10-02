defmodule LLMAgent.Tool.Adapter.OpenAIChatStreamTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias LLMAgent.Codec.OpenAI, as: Codec
  alias LLMAgent.Tool.Adapter.OpenAIChat
  alias LLMAgent.Turn
  alias LLMAgent.WireFixtures

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, payload: %{api_host: "http://localhost:#{bypass.port}", model: "performer-model"}}
  end

  defp turn do
    %Turn{
      model: "client-model",
      messages: [%{role: :user, content: [%{type: :text, text: "weather?", extra: %{}}], extra: %{}}],
      stream: false
    }
  end

  # Collects events in the test process and keeps the stream going.
  defp collector do
    test = self()

    fn event ->
      send(test, {:event, event})
      :cont
    end
  end

  defp received_events(acc \\ []) do
    receive do
      {:event, event} -> received_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp serve(bypass, status, body, content_type \\ "text/event-stream") do
    test = self()

    Bypass.expect_once(bypass, "POST", "/chat/completions", fn conn ->
      {:ok, request, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, Jason.decode!(request)})

      conn
      |> Plug.Conn.put_resp_content_type(content_type)
      |> Plug.Conn.resp(status, body)
    end)
  end

  test "streams a recorded two-tool reply into canonical events and a folded message", ctx do
    raw = WireFixtures.read("openai_two_tools_stream.sse")
    serve(ctx.bypass, 200, raw)

    assert {:ok, message, provenance} =
             OpenAIChat.generate(ctx.payload, "chat", %{turn: turn()}, into: collector())

    assert [%{input: %{"city" => "Paris"}}, %{input: %{"city" => "Oslo"}}] =
             Enum.filter(message.content, &(&1.type == :tool_call))

    assert provenance.stop_reason == :tool_use
    assert is_integer(provenance.usage.input_tokens) and is_integer(provenance.usage.output_tokens)
    assert is_integer(provenance.latency_ms) and provenance.latency_ms >= 0
    assert is_binary(provenance.model)

    {expected, state} = Codec.decode_stream(Codec.stream_decoder(), raw)
    assert received_events() == expected ++ Codec.finish_stream(state)
  end

  test "asks the performer to stream with usage, under the binding's model", ctx do
    serve(ctx.bypass, 200, WireFixtures.read("openai_text_stream.sse"))

    assert {:ok, _message, _provenance} = OpenAIChat.generate(ctx.payload, "chat", %{turn: turn()}, [])

    assert_received {:request, request}
    assert request["stream"] == true
    assert request["stream_options"] == %{"include_usage" => true}
    assert request["model"] == "performer-model"
    assert [%{"role" => "user", "content" => "weather?"}] = request["messages"]
  end

  test "works without an into function", ctx do
    serve(ctx.bypass, 200, WireFixtures.read("openai_text_stream.sse"))

    assert {:ok, %{role: :assistant, content: content}, %{stop_reason: :end_turn}} =
             OpenAIChat.generate(ctx.payload, "chat", %{turn: turn()}, [])

    assert %{type: :text, text: "hello there"} = List.last(content)
  end

  test "a chat-template failure is an http error carrying the performer's message", ctx do
    serve(ctx.bypass, 500, WireFixtures.read("openai_error_500_template.json"), "application/json")

    assert {:error, {:http_error, 500, body}} =
             OpenAIChat.generate(ctx.payload, "chat", %{turn: turn()}, into: collector())

    assert is_binary(body["error"]["message"])
    assert received_events() == []
  end

  test "a rejected request is an http error with its status", ctx do
    serve(ctx.bypass, 400, WireFixtures.read("openai_error_400.json"), "application/json")

    assert {:error, {:http_error, 400, %{"error" => %{"message" => _}}}} =
             OpenAIChat.generate(ctx.payload, "chat", %{turn: turn()}, into: collector())

    assert received_events() == []
  end

  test "an error body that is not JSON is kept as text", ctx do
    serve(ctx.bypass, 503, "upstream unavailable", "text/plain")

    assert {:error, {:http_error, 503, "upstream unavailable"}} =
             OpenAIChat.generate(ctx.payload, "chat", %{turn: turn()}, [])
  end

  test "a reply that ends without finishing is an error, and the stream is told", ctx do
    raw = WireFixtures.read("openai_tool_stream.sse")
    serve(ctx.bypass, 200, binary_part(raw, 0, div(byte_size(raw), 2)))

    assert {:error, :incomplete_stream} =
             OpenAIChat.generate(ctx.payload, "chat", %{turn: turn()}, into: collector())

    assert List.last(received_events()) == {:error, :incomplete_stream}
  end

  # Bypass cannot stand in here: the point is a performer still mid-reply when
  # the caller walks away, and Bypass treats its handler being cut off as a
  # test failure. A bare socket also lets the test see the connection close.
  test "halting cancels the upstream request promptly" do
    raw = WireFixtures.read("openai_text_stream.sse")
    head = binary_part(raw, 0, div(byte_size(raw), 2))
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    performer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 5_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n",
            Integer.to_string(byte_size(head), 16),
            "\r\n",
            head,
            "\r\n"
          ])

        # Never finishes the reply; reports how the connection ended.
        drain(socket)
      end)

    payload = %{api_host: "http://localhost:#{port}", model: "performer-model"}
    started = System.monotonic_time(:millisecond)

    assert {:error, :halted} = OpenAIChat.generate(payload, "chat", %{turn: turn()}, into: fn _event -> :halt end)
    assert System.monotonic_time(:millisecond) - started < 1_000
    assert Task.await(performer, 5_000) == :closed
  end

  # A killed performer: the socket closes with the chunked body unterminated.
  test "a performer that dies mid-reply is an error, and the stream is told" do
    raw = WireFixtures.read("openai_text_stream.sse")
    head = binary_part(raw, 0, div(byte_size(raw), 2))
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    performer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 5_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n",
            Integer.to_string(byte_size(head), 16),
            "\r\n",
            head,
            "\r\n"
          ])

        Process.sleep(100)
        :gen_tcp.close(socket)
      end)

    payload = %{api_host: "http://localhost:#{port}", model: "performer-model"}

    assert {:error, reason} = OpenAIChat.generate(payload, "chat", %{turn: turn()}, into: collector())
    refute reason == :halted
    Task.await(performer, 5_000)

    events = received_events()
    assert match?({:start, _}, hd(events))
    assert {:error, _} = List.last(events)
    assert Enum.count(events, &match?({:error, _}, &1)) == 1
  end

  defp drain(socket) do
    case :gen_tcp.recv(socket, 0, 3_000) do
      {:ok, _more_request_bytes} -> drain(socket)
      {:error, reason} -> reason
    end
  end

  test "a performer that is not listening is an error, not a raise", ctx do
    Bypass.down(ctx.bypass)

    assert {:error, _reason} = OpenAIChat.generate(ctx.payload, "chat", %{turn: turn()}, into: collector())
    assert received_events() == []
  end

  test "the legacy messages clause is untouched", ctx do
    Bypass.expect_once(ctx.bypass, "POST", "/chat/completions", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"choices":[{"message":{"content":"hello back"}}]}))
    end)

    assert {:ok, "hello back", %{model: "performer-model"}} =
             OpenAIChat.generate(ctx.payload, "chat", %{messages: [%{"role" => "user", "content" => "hi"}]}, [])
  end
end

defmodule LLMAgent.Codec.SSETest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias LLMAgent.Codec.SSE
  alias LLMAgent.WireFixtures

  defp feed_all(chunks) do
    {frames, _state} =
      Enum.reduce(chunks, {[], SSE.new()}, fn chunk, {acc, state} ->
        {frames, state} = SSE.feed(state, chunk)
        {acc ++ frames, state}
      end)

    frames
  end

  defp data_line_count(raw),
    do: raw |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "data: "))

  test "an OpenAI stream fed whole yields one frame per data line" do
    raw = WireFixtures.read("openai_tool_stream.sse")
    frames = feed_all([raw])

    assert length(frames) == data_line_count(raw)

    for %{data: data} <- frames do
      assert data == "[DONE]" or match?({:ok, _}, Jason.decode(data))
    end
  end

  test "feeding one byte at a time yields the same frames" do
    raw = WireFixtures.read("openai_tool_stream.sse")
    assert feed_all(WireFixtures.bytes(raw)) == feed_all([raw])
  end

  test "an Anthropic stream carries an event name equal to the JSON type" do
    frames = feed_all([WireFixtures.read("anthropic_tool_stream.sse")])

    assert frames != []

    for %{event: event, data: data} <- frames do
      assert is_binary(event)
      assert Jason.decode!(data)["type"] == event
    end
  end

  test "a stream cut mid-frame yields only the complete frames before the cut" do
    raw = WireFixtures.read("openai_tool_stream.sse")
    all = feed_all([raw])
    cut = binary_part(raw, 0, div(byte_size(raw), 2))

    # The cut must land inside a frame for this test to mean anything.
    refute String.ends_with?(cut, "\n\n")

    frames = feed_all([cut])
    assert frames == Enum.take(all, length(frames))
    assert length(frames) == length(:binary.matches(cut, "\n\n"))
  end

  test "a multi-byte character split across two chunks arrives intact" do
    [first | _] = feed_all([WireFixtures.read("openai_text_stream.sse")])
    text = "héllo ✓"

    frame =
      first.data
      |> Jason.decode!()
      |> put_in(["choices", Access.at(0), "delta", "content"], text)
      |> Jason.encode!()
      |> then(&("data: " <> &1 <> "\n\n"))

    {at, 2} = :binary.match(frame, "é")
    <<head::binary-size(at + 1), tail::binary>> = frame

    assert [%{data: data}] = feed_all([head, tail])
    assert get_in(Jason.decode!(data), ["choices", Access.at(0), "delta", "content"]) == text
  end

  test "CRLF line endings yield the same frames as LF" do
    raw = WireFixtures.read("anthropic_tool_stream.sse")
    crlf = String.replace(raw, "\n", "\r\n")

    assert feed_all([crlf]) == feed_all([raw])
    assert feed_all(WireFixtures.bytes(crlf)) == feed_all([raw])
  end
end

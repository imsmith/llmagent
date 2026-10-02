defmodule LLMAgent.Codec.SSE do
  @moduledoc """
  Splits a byte stream into Server-Sent Events frames.

  Network chunks do not respect frame boundaries: a frame, a line, or a single
  multi-byte character can be split across two chunks. `feed/2` returns the
  frames completed so far and keeps the unfinished tail in its state.

  A frame ends at a blank line. `data:` lines within a frame are joined with a
  newline, an `event:` line names the frame, and lines starting with `:` are
  comments. Both `\\n` and `\\r\\n` line endings are accepted.

  ## Examples

      iex> alias LLMAgent.Codec.SSE
      iex> {[], state} = SSE.feed(SSE.new(), "event: ping\\ndata: {\\"a\\"")
      iex> {frames, _state} = SSE.feed(state, ":1}\\n\\n")
      iex> frames
      [%{event: "ping", data: "{\\"a\\":1}"}]
  """

  @typedoc "Bytes received but not yet part of a complete frame."
  @opaque t :: binary()

  @type frame :: %{event: String.t() | nil, data: String.t()}

  @doc "A fresh splitter state."
  @spec new() :: t()
  def new, do: ""

  @doc "Feed the next chunk; returns the frames it completed and the new state."
  @spec feed(t(), binary()) :: {[frame()], t()}
  def feed(state, chunk) when is_binary(state) and is_binary(chunk) do
    {work, held} = hold_trailing_cr(state <> chunk)

    {complete, [rest]} =
      work
      |> :binary.replace("\r\n", "\n", [:global])
      |> :binary.split("\n\n", [:global])
      |> Enum.split(-1)

    {Enum.flat_map(complete, &parse_frame/1), rest <> held}
  end

  # A chunk ending in "\r" may be the first half of a "\r\n"; it cannot be
  # judged until the next byte arrives.
  defp hold_trailing_cr(buffer) do
    size = byte_size(buffer)

    if size > 0 and :binary.last(buffer) == ?\r do
      {binary_part(buffer, 0, size - 1), "\r"}
    else
      {buffer, ""}
    end
  end

  defp parse_frame(raw) do
    {event, data} =
      raw
      |> :binary.split("\n", [:global])
      |> Enum.reduce({nil, []}, &parse_line/2)

    case {event, data} do
      {nil, []} -> []
      _ -> [%{event: event, data: data |> Enum.reverse() |> Enum.join("\n")}]
    end
  end

  defp parse_line(":" <> _comment, acc), do: acc
  defp parse_line("data:" <> value, {event, data}), do: {event, [strip_space(value) | data]}
  defp parse_line("event:" <> value, {_event, data}), do: {strip_space(value), data}
  defp parse_line(_other, acc), do: acc

  defp strip_space(" " <> value), do: value
  defp strip_space(value), do: value
end

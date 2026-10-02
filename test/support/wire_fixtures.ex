defmodule LLMAgent.WireFixtures do
  @moduledoc """
  Access to `test/fixtures/wire/` — wire traffic recorded from the live
  llama-servers and from a real Claude Code client. Never edit those files by
  hand; re-record them.
  """

  @dir Path.expand("../fixtures/wire", __DIR__)

  @doc "Raw bytes of a recorded fixture."
  @spec read(String.t()) :: binary()
  def read(name), do: File.read!(Path.join(@dir, name))

  @doc "A recorded JSON fixture, decoded."
  @spec json(String.t()) :: map()
  def json(name), do: name |> read() |> Jason.decode!()

  @doc "Every byte of a binary as its own one-byte chunk."
  @spec bytes(binary()) :: [binary()]
  def bytes(binary), do: for(<<b <- binary>>, do: <<b>>)
end

defmodule LLMAgent.Utils.Time do
  @moduledoc """
  Time-related utilities: formatting, parsing, and conversion.

  Currently supports:
    - "now_iso8601": Returns the current UTC time in ISO8601 format
  """

  @behaviour LLMAgent.Util

  @impl true
  def describe do
    "Provides UTC time formatting utilities, including ISO8601 timestamp generation."
  end

  @impl true
  def capabilities do
    ["now_iso8601"]
  end

  @impl true
  def call("now_iso8601", _args) do
    {:ok, DateTime.utc_now() |> DateTime.to_iso8601()}
  end

  def call(_, _), do: {:error, :unsupported_time_action}
end

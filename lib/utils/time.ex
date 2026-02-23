defmodule LLMAgent.Utils.Time do
  @moduledoc """
  Time-related utilities: formatting, parsing, and conversion.

  ## Examples

      iex> {:ok, ts} = LLMAgent.Utils.Time.call("now_iso8601", %{})
      iex> {:ok, _, _} = DateTime.from_iso8601(ts)
  """

  @behaviour LLMAgent.Util

  @doc """
  Returns a description of available time utilities.

  ## Examples

      iex> LLMAgent.Utils.Time.describe()
      ...> |> is_binary()
      true
  """
  @impl true
  def describe do
    "Provides UTC time formatting utilities, including ISO8601 timestamp generation."
  end

  @doc """
  Lists supported time actions.

  ## Examples

      iex> LLMAgent.Utils.Time.capabilities()
      ["now_iso8601"]
  """
  @impl true
  def capabilities do
    ["now_iso8601"]
  end

  @doc """
  Execute a time action.

  ## Examples

      iex> {:ok, ts} = LLMAgent.Utils.Time.call("now_iso8601", %{})
      iex> String.contains?(ts, "T")
      true

      iex> LLMAgent.Utils.Time.call("bogus", %{})
      {:error, :unsupported_time_action}
  """
  @impl true
  def call("now_iso8601", _args) do
    {:ok, DateTime.utc_now() |> DateTime.to_iso8601()}
  end

  def call(_, _), do: {:error, :unsupported_time_action}
end

defmodule LLMAgent.Utils.Encoder do
  @moduledoc """
  Encodes binary data to base16, base64, base58, or raw.

  ## Examples

      iex> LLMAgent.Utils.Encoder.call("base16", %{"data" => "hi"})
      {:ok, "6869"}

      iex> LLMAgent.Utils.Encoder.call("base64", %{"data" => "hi"})
      {:ok, "aGk="}

      iex> LLMAgent.Utils.Encoder.call("raw", %{"data" => "hi"})
      {:ok, "hi"}
  """

  @behaviour LLMAgent.Util

  @doc """
  Returns a description of available encodings.

  ## Examples

      iex> LLMAgent.Utils.Encoder.describe()
      ...> |> is_binary()
      true
  """
  @impl true
  def describe do
    """
    Encoder utility that transforms binary input into:
      - base16 (hex, lowercase)
      - base64 (standard)
      - base64url (URL-safe, no padding)
      - base58 (IPFS/BTC style)
      - raw (binary passthrough)
    """
  end

  @doc """
  Lists supported encoding formats.

  ## Examples

      iex> LLMAgent.Utils.Encoder.capabilities()
      ["base16", "base64", "base64url", "base58", "raw"]
  """
  @impl true
  def capabilities do
    ["base16", "base64", "base64url", "base58", "raw"]
  end

  @doc """
  Encode binary data in the specified format.

  ## Examples

      iex> LLMAgent.Utils.Encoder.call("base16", %{"data" => <<255, 0>>})
      {:ok, "ff00"}

      iex> LLMAgent.Utils.Encoder.call("base64", %{"data" => "hello"})
      {:ok, "aGVsbG8="}

      iex> LLMAgent.Utils.Encoder.call("nope", %{"data" => "x"})
      {:error, :unsupported_encoding}
  """
  @impl true
  def call("base16", %{"data" => bin}) when is_binary(bin),
    do: {:ok, Base.encode16(bin, case: :lower)}

  def call("base64", %{"data" => bin}), do: {:ok, Base.encode64(bin)}
  def call("base64url", %{"data" => bin}), do: {:ok, Base.encode64(bin, padding: false)}
  def call("base58", %{"data" => bin}), do: {:ok, Base58.encode(bin)}
  def call("raw", %{"data" => bin}), do: {:ok, bin}

  def call(_, _), do: {:error, :unsupported_encoding}
end

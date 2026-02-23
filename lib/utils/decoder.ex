defmodule LLMAgent.Utils.Decoder do
  @moduledoc """
  Decodes encoded strings back to binary.

  ## Examples

      iex> LLMAgent.Utils.Decoder.decode("6869", "base16")
      {:ok, "hi"}

      iex> LLMAgent.Utils.Decoder.decode("aGk=", "base64")
      {:ok, "hi"}

      iex> LLMAgent.Utils.Decoder.decode("hello", "raw")
      {:ok, "hello"}
  """

  @doc """
  Decodes a string based on the specified encoding type.

  Supported encodings: `"base16"`, `"base64"`, `"base64url"`, `"base58"`, `"raw"`.

  ## Examples

      iex> LLMAgent.Utils.Decoder.decode("ff00", "base16")
      {:ok, <<255, 0>>}

      iex> LLMAgent.Utils.Decoder.decode("aGVsbG8=", "base64")
      {:ok, "hello"}

      iex> LLMAgent.Utils.Decoder.decode("x", "nope")
      {:error, "Unsupported encoding: nope"}
  """
  @spec decode(String.t(), String.t()) :: binary() | {:error, term()}
  def decode(str, "base16"), do: Base.decode16(str, case: :mixed)
  def decode(str, "base64"), do: Base.decode64(str)
  def decode(str, "base64url"), do: Base.decode64(str, padding: false)
  def decode(str, "base58"), do: Base58.decode(str)
  def decode(str, "raw"), do: {:ok, str}
  def decode(_, other), do: {:error, "Unsupported encoding: #{other}"}
end

defmodule LLMAgent.Utils.Decoder do
  @moduledoc """
  A module for decoding various encoded strings.
  """

  @doc """
  Decodes a given string based on the specified encoding type.

  ## Parameters

    - str: The string to decode.
    - encoding: The encoding type. Supported types are "base16", "base64", "base64url", "base58", and "raw".

  ## Returns

    - {:ok, decoded_string} if decoding is successful.
    - {:error, reason} if decoding fails.
  """
  @spec decode(String.t(), String.t()) :: binary() | {:error, term()}
  def decode(str, "base16"), do: Base.decode16(str, case: :mixed)
  def decode(str, "base64"), do: Base.decode64(str)
  def decode(str, "base64url"), do: Base.decode64(str, padding: false)
  def decode(str, "base58"), do: Base58.decode(str)
  def decode(str, "raw"), do: {:ok, str}
  def decode(_, other), do: {:error, "Unsupported encoding: #{other}"}

end

defmodule LLMAgent.Tools.Crypto do
  @moduledoc "Cryptographic tools for hashing, signing, verifying, and key generation."
  @behaviour LLMAgent.Tool

  @impl true
  def describe do
    "Hashes data, generates keys, and verifies signatures using secure primitives."
  end

  @impl true
  def perform("sha256", %{"data" => data}) when is_binary(data) do
    hash = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
    {:ok, hash}
  end

  def perform("hmac", %{"key" => key, "data" => data}) do
    hmac = :crypto.mac(:hmac, :sha256, key, data) |> Base.encode16(case: :lower)
    {:ok, hmac}
  end

  def perform(_, _), do: {:error, :unknown_command}
end

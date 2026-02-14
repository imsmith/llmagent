defmodule LLMAgent.Tools.CryptoTest do
  use ExUnit.Case, async: true

  alias LLMAgent.Tools.Crypto
  alias Comn.Errors.ErrorStruct

  describe "describe/0" do
    test "returns a string summary" do
      assert is_binary(Crypto.describe())
    end
  end

  describe "perform/2" do
    test "returns error for unknown command" do
      {:error, %ErrorStruct{reason: "unknown_command"}} = Crypto.perform("not_real", %{})
    end

    test "sha256 hashes data" do
      {:ok, %{output: hash, metadata: %{algorithm: "sha256"}}} =
        Crypto.perform("sha256", %{"data" => "hello"})

      assert is_binary(hash)
      assert String.length(hash) == 64
    end

    test "generates symmetric key" do
      {:ok, %{output: key, metadata: %{type: "symmetric", bits: 256}}} =
        Crypto.perform("generate_key", %{})

      assert is_binary(key)
    end

    test "generates ed25519 keypair" do
      {:ok, %{output: %{type: "ed25519", private_key: priv, public_key: pub}, metadata: _}} =
        Crypto.perform("generate_keypair", %{"type" => "ed25519"})

      assert is_binary(priv)
      assert is_binary(pub)
    end

    test "sign and verify ed25519" do
      {:ok, %{output: %{private_key: priv, public_key: pub}}} =
        Crypto.perform("generate_keypair", %{"type" => "ed25519"})

      {:ok, %{output: sig}} =
        Crypto.perform("sign", %{"type" => "ed25519", "data" => "test", "private_key" => priv})

      {:ok, %{output: true}} =
        Crypto.perform("verify", %{"type" => "ed25519", "data" => "test", "signature" => sig, "public_key" => pub})
    end
  end
end

defmodule LLMAgent.Tools.CryptoTest do
  @moduledoc false

  use ExUnit.Case, async: false

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

  describe "tool-discovery substrate (via Dispatcher)" do
    alias LLMAgent.{Tools.Crypto, Tools.Discovery, Tool.Dispatcher, Tool.Policy}

    setup do
      case Process.whereis(Discovery) do
        nil -> {:ok, _} = Discovery.start_link(consume_announcements: false)
        _ -> Discovery.reset!()
      end

      LLMAgent.Tool.Bindings.init_registry()
      LLMAgent.Tool.Kinds.init_registry()
      :ok = Discovery.register(Crypto.ad())
      :ok
    end

    test "ad/0 returns a well-formed ToolAd for function.crypto" do
      ad = Crypto.ad()
      assert ad.coordinate == "function.crypto"
      assert :compute in ad.kinds
      assert ad.binding == {:module, Crypto}
      assert ad.fidelity == :authoritative
    end

    test "dispatcher.compute/4 sha256 returns the digest" do
      policy = %Policy{allow: ["function.crypto"], fidelity_min: :authoritative}

      assert {:ok, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"} =
               Dispatcher.compute("function.crypto", "sha256", %{"data" => "hello"},
                 policy: policy)
    end

    test "dispatcher denies when policy.allow is empty" do
      assert {:error, :forbidden, :not_allowed} =
               Dispatcher.compute("function.crypto", "sha256", %{"data" => "hello"},
                 policy: %Policy{})
    end
  end
end

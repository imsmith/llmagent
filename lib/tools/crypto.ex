defmodule LLMAgent.Tools.Crypto do
  @moduledoc """
  Cryptographic tools for hashing, HMAC, signing, verifying, and key generation.

  Supported actions:
    - "sha256": hashes binary input with SHA-256
    - "hmac": calculates HMAC-SHA256 for given key and data
    - "generate_key": creates a 256-bit symmetric key (Base64)
    - "generate_keypair": creates asymmetric keypair (Ed25519 or ECDSA)
    - "sign": signs data with a private key (Ed25519 or ECDSA)
    - "verify": verifies signature with a public key

  ### ECDSA input format:
    - public_key: Base64-encoded uncompressed EC point (65 bytes, starts with 0x04)
    - signature: Base64-encoded binary (DER format)
    - curve: "secp256r1" (hardcoded)

  ### Ed25519 input format:
    - public/private keys: Base64-encoded 32-byte raw binary
    - signature: Base64-encoded 64-byte signature

  ### ECDSA input format:
    - For ecdsa verification, provide the public key as a PEM-encoded ECDSA public key (Base64 encoded PEM text)
  """

  @behaviour LLMAgent.Tool
  alias LLMAgent.Utils.Encoder

  @impl true
  def describe do
    """
    Cryptographic operations for agents.

    ### Supported:
    - `sha256`: hash data using SHA-256
    - `hmac`: keyed HMAC-SHA256
    - `generate_key`: random 256-bit symmetric key (Base64)
    - `generate_keypair`: asymmetric keypairs for `ed25519` or `ecdsa`
    - `sign`: sign data using a private key
    - `verify`: verify a signature with a public key

    ### ECDSA input format:
    - public_key: Base64-encoded uncompressed EC point (65 bytes, starts with 0x04)
    - signature: Base64-encoded binary (DER format)
    - curve: "secp256r1" (hardcoded)

    ### Ed25519 input format:
    - public/private keys: Base64-encoded 32-byte binary
    - signature: Base64-encoded 64-byte signature

    ### ECDSA input format:
    - For ecdsa verification, provide the public key as a PEM-encoded ECDSA public key (Base64 encoded PEM text)
    """
  end

  @impl true
  def perform("sha256", %{"data" => data} = args) when is_binary(data) do
    raw = :crypto.hash(:sha256, data)
    encode(raw, args)
  end

  def perform("hmac", %{"key" => key, "data" => data} = args)
      when is_binary(key) and is_binary(data) do
    raw = :crypto.mac(:hmac, :sha256, key, data)
    encode(raw, args)
  end

  def perform("generate_key", _args) do
    key = :crypto.strong_rand_bytes(32) |> Base.encode64()
    {:ok, key}
  end

  def perform("generate_keypair", %{"type" => "ed25519"}) do
    {priv, pub} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, %{
      type: "ed25519",
      private_key: Base.encode64(priv),
      public_key: Base.encode64(pub)
    }}
  end

  def perform("generate_keypair", %{"type" => "ecdsa"}) do
    {:ECPrivateKey, _, priv, params, pub, _} =
      :public_key.generate_key({:namedCurve, :secp256r1})

    {:ok, %{
      type: "ecdsa",
      curve: "secp256r1",
      private_key: Base.encode64(:erlang.term_to_binary({:ECPrivateKey, 1, priv, params, pub, :asn1_NOVALUE})),
      public_key: Base.encode64(pub)
    }}
  end

  def perform("sign", %{
        "type" => "ed25519",
        "data" => data,
        "private_key" => priv_b64
      }) do
    with {:ok, priv} <- Base.decode64(priv_b64) do
      sig = :crypto.sign(:eddsa, :none, data, [priv, :ed25519])
      {:ok, Base.encode64(sig)}
    else
      _ -> {:error, "Invalid Ed25519 private key"}
    end
  end

  def perform("verify", %{
        "type" => "ed25519",
        "data" => data,
        "signature" => sig_b64,
        "public_key" => pub_b64
      }) do
    with {:ok, pub} <- Base.decode64(pub_b64),
         {:ok, sig} <- Base.decode64(sig_b64) do
      result = :crypto.verify(:eddsa, :none, data, sig, [pub, :ed25519])
      {:ok, result}
    else
      _ -> {:error, "Invalid Ed25519 signature or public key"}
    end
  end

  def perform("verify", %{
    "type" => "ecdsa",
    "data" => data,
    "signature" => sig64,
    "public_key" => pem64
  }) do
    with {:ok, sig} <- Base.decode64(sig64),
         {:ok, pem_bin} <- Base.decode64(pem64),
         [entry] <- :public_key.pem_decode(pem_bin),
         pub_key <- :public_key.pem_entry_decode(entry),
         result <- :public_key.verify(data, :sha256, sig, pub_key) do
      {:ok, result}
    else
      _ -> {:error, "Invalid ECDSA signature or public key format"}
    end
  end


  def perform(_, _), do: {:error, :unknown_command}

  defp encode(raw, args) do
    encoding = Map.get(args, "encoding", "base16")

    case Encoder.call(encoding, %{"data" => raw}) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _} = err -> err
    end
  end
end

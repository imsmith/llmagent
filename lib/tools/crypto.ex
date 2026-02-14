defmodule LLMAgent.Tools.Crypto do
  @moduledoc """
  Cryptographic tools for hashing, HMAC, signing, verifying, and key generation.

  Supported actions:
    - "sha256": hashes binary input with SHA-256
    - "hmac": calculates HMAC-SHA256 for given key and data
    - "generate_key": creates a 256-bit symmetric key (Base64)
    - "generate_keypair": creates asymmetric keypair (Ed25519 or ECDSA)
    - "sign": signs data with a private key (Ed25519)
    - "verify": verifies signature with a public key (Ed25519 or ECDSA)
  """

  @behaviour LLMAgent.Tool
  alias LLMAgent.Utils.Encoder
  alias Comn.Errors.ErrorStruct

  @impl true
  def describe do
    """
    Cryptographic operations for agents.

    Supported:
    - `sha256`: hash data using SHA-256
    - `hmac`: keyed HMAC-SHA256
    - `generate_key`: random 256-bit symmetric key (Base64)
    - `generate_keypair`: asymmetric keypairs for `ed25519` or `ecdsa`
    - `sign`: sign data using a private key
    - `verify`: verify a signature with a public key
    """
  end

  @impl true
  def perform("sha256", %{"data" => data} = args) when is_binary(data) do
    raw = :crypto.hash(:sha256, data)
    encode(raw, args, %{algorithm: "sha256"})
  end

  def perform("hmac", %{"key" => key, "data" => data} = args)
      when is_binary(key) and is_binary(data) do
    raw = :crypto.mac(:hmac, :sha256, key, data)
    encode(raw, args, %{algorithm: "hmac-sha256"})
  end

  def perform("generate_key", _args) do
    key = :crypto.strong_rand_bytes(32) |> Base.encode64()
    {:ok, %{output: key, metadata: %{type: "symmetric", bits: 256}}}
  end

  def perform("generate_keypair", %{"type" => "ed25519"}) do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, %{
      output: %{
        type: "ed25519",
        private_key: Base.encode64(priv),
        public_key: Base.encode64(pub)
      },
      metadata: %{type: "ed25519"}
    }}
  end

  def perform("generate_keypair", %{"type" => "ecdsa"}) do
    {:ECPrivateKey, _, priv, params, pub, _} =
      :public_key.generate_key({:namedCurve, :secp256r1})

    {:ok, %{
      output: %{
        type: "ecdsa",
        curve: "secp256r1",
        private_key: Base.encode64(:erlang.term_to_binary({:ECPrivateKey, 1, priv, params, pub, :asn1_NOVALUE})),
        public_key: Base.encode64(pub)
      },
      metadata: %{type: "ecdsa", curve: "secp256r1"}
    }}
  end

  def perform("sign", %{
        "type" => "ed25519",
        "data" => data,
        "private_key" => priv_b64
      }) do
    with {:ok, priv} <- Base.decode64(priv_b64) do
      sig = :crypto.sign(:eddsa, :none, data, [priv, :ed25519])
      {:ok, %{output: Base.encode64(sig), metadata: %{type: "ed25519", action: "sign"}}}
    else
      _ -> {:error, ErrorStruct.new("invalid_key", "private_key", "Invalid Ed25519 private key")}
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
      {:ok, %{output: result, metadata: %{type: "ed25519", action: "verify"}}}
    else
      _ -> {:error, ErrorStruct.new("invalid_key", "public_key", "Invalid Ed25519 signature or public key")}
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
      {:ok, %{output: result, metadata: %{type: "ecdsa", action: "verify"}}}
    else
      _ -> {:error, ErrorStruct.new("invalid_key", "public_key", "Invalid ECDSA signature or public key format")}
    end
  end

  def perform(_, _),
    do: {:error, ErrorStruct.new("unknown_command", nil, "Unrecognized Crypto action")}

  defp encode(raw, args, metadata) do
    encoding = Map.get(args, "encoding", "base16")

    case Encoder.call(encoding, %{"data" => raw}) do
      {:ok, encoded} -> {:ok, %{output: encoded, metadata: Map.put(metadata, :encoding, encoding)}}
      {:error, _} = err -> err
    end
  end
end

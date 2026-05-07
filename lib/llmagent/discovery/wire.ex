defmodule LLMAgent.Discovery.Wire do
  @moduledoc """
  EDN codec for the discovery wire protocol. Translates between EDN text
  lines emitted by discovery shims and `{event, payload}` tuples consumed by
  `LLMAgent.Discovery.PortAdapter`.

  Two events are supported:

  - `{:register, %LLMAgent.ToolAd{}}` — shim wants the registry to know about
    a tool. The adapter calls `Tools.Discovery.register/1` and falls back to
    `update/1` on `:duplicate_id`.
  - `{:expire, ad_id}` — shim observed the source go away. The adapter calls
    `Tools.Discovery.unregister/1`.

  ## Wire format

  Each message is a single EDN map on one line (no internal newlines).

  Register:

  ```text
  {:event :register :ad {:id "..." :coordinate "..." :kinds [:generate]
    :binding [:openai_chat {...}] :operational {...} :constraint {...}
    :affordance {...} :fidelity :authoritative :provenance {...}
    :lease [:expires_at "2026-05-07T15:01:00Z"]}}
  ```

  Expire:

  ```text
  {:event :expire :id "..."}
  ```

  ## Eden type notes

  - EDN keywords (`:foo`) decode to Elixir atoms.
  - EDN vectors (`[...]`) decode to `Array` structs; the codec converts them
    to Elixir lists on the way in and back to `Array` structs on the way out.
  - Elixir tuples cannot be encoded by Eden — use `Array.from_list/1` to
    produce EDN vectors for `:binding` and `:lease`.
  - `nil` encodes/decodes as EDN `nil`.

  See `docs/superpowers/specs/2026-05-07-mdns-llm-discovery.md`.
  """

  alias LLMAgent.ToolAd

  @type event :: {:register, ToolAd.t()} | {:expire, binary()}

  @doc """
  Decode one EDN line into a `{event, payload}` tuple.

  Returns `{:ok, {:register, %ToolAd{}}}`, `{:ok, {:expire, ad_id}}`, or
  `{:error, reason}` on malformed input or unknown event type.
  """
  @spec decode(binary()) :: {:ok, event()} | {:error, term()}
  def decode(line) when is_binary(line) do
    case Eden.decode(line) do
      {:ok, decoded} -> classify(decoded)
      {:error, _} = err -> err
    end
  end

  @doc """
  Encode a `:register` event for a `%ToolAd{}` as one EDN line.

  Returns `{:ok, binary()}` on success or `{:error, reason}` if any field
  cannot be encoded.
  """
  @spec encode_register(ToolAd.t()) :: {:ok, binary()} | {:error, term()}
  def encode_register(%ToolAd{} = ad) do
    Eden.encode(%{event: :register, ad: ad_to_map(ad)})
  end

  # ---------------------------------------------------------------------------
  # Private — classify decoded EDN
  # ---------------------------------------------------------------------------

  @spec classify(map()) :: {:ok, event()} | {:error, term()}
  defp classify(%{event: :register, ad: ad_map}) do
    case to_ad(ad_map) do
      {:ok, ad} -> {:ok, {:register, ad}}
      {:error, _} = err -> err
    end
  end

  defp classify(%{event: :expire, id: id}) when is_binary(id) do
    {:ok, {:expire, id}}
  end

  defp classify(%{event: unknown}) do
    {:error, {:unknown_event, unknown}}
  end

  defp classify(_other) do
    {:error, :malformed_event}
  end

  # ---------------------------------------------------------------------------
  # Private — decode: EDN map → %ToolAd{}
  # ---------------------------------------------------------------------------

  @spec to_ad(map()) :: {:ok, ToolAd.t()} | {:error, term()}
  defp to_ad(m) when is_map(m) do
    try do
      ad =
        ToolAd.new(%{
          id: Map.fetch!(m, :id),
          coordinate: Map.fetch!(m, :coordinate),
          kinds: m |> Map.fetch!(:kinds) |> array_to_list(),
          binding: m |> Map.fetch!(:binding) |> decode_binding(),
          operational: m |> Map.fetch!(:operational) |> normalise_map(),
          constraint: m |> Map.fetch!(:constraint) |> normalise_map(),
          affordance: m |> Map.fetch!(:affordance) |> decode_affordance(),
          fidelity: Map.fetch!(m, :fidelity),
          provenance: m |> Map.fetch!(:provenance) |> decode_provenance(),
          lease: m |> Map.fetch!(:lease) |> decode_lease()
        })

      {:ok, ad}
    rescue
      e in [KeyError, ArgumentError] -> {:error, e}
    end
  end

  defp to_ad(_), do: {:error, :bad_ad}

  # EDN vector `[:openai_chat {...}]` → `{:openai_chat, map}`
  @spec decode_binding(Array.t() | list()) :: {atom(), map()}
  defp decode_binding(v) do
    [kind, payload] = array_to_list(v)
    {kind, normalise_map(payload)}
  end

  # EDN vector `[:expires_at "ISO8601"]` → `{:expires_at, DateTime.t()}`
  # or the atom `:permanent`
  @spec decode_lease(Array.t() | list() | atom()) ::
          :permanent | {:expires_at, DateTime.t()}
  defp decode_lease(:permanent), do: :permanent

  defp decode_lease(v) do
    [:expires_at, iso] = array_to_list(v)
    {:ok, dt, _} = DateTime.from_iso8601(iso)
    {:expires_at, dt}
  end

  # `%{produced_at: "ISO8601", ...}` → `%{produced_at: DateTime.t(), ...}`
  @spec decode_provenance(map()) :: map()
  defp decode_provenance(m) when is_map(m) do
    {:ok, dt, _} = DateTime.from_iso8601(Map.fetch!(m, :produced_at))

    m
    |> Map.put(:produced_at, dt)
    |> Map.update(:based_on, [], &array_to_list/1)
  end

  # Affordance has `declared` and `learned` as EDN vectors; convert them.
  @spec decode_affordance(map()) :: map()
  defp decode_affordance(m) when is_map(m) do
    m
    |> Map.update!(:declared, &array_to_list/1)
    |> Map.update!(:learned, &array_to_list/1)
  end

  # Recursively walk a decoded map; converts any nested Array values to lists.
  # Leaves non-map leaf values untouched.
  @spec normalise_map(map() | term()) :: map() | term()
  defp normalise_map(m) when is_map(m) do
    Map.new(m, fn {k, v} -> {k, normalise_value(v)} end)
  end

  defp normalise_map(other), do: other

  @spec normalise_value(term()) :: term()
  defp normalise_value(%Array{} = arr), do: arr |> Enum.to_list() |> Enum.map(&normalise_value/1)
  defp normalise_value(m) when is_map(m), do: normalise_map(m)
  defp normalise_value(other), do: other

  # Convert Array or list to plain Elixir list.
  @spec array_to_list(Array.t() | list()) :: list()
  defp array_to_list(%Array{} = arr), do: Enum.to_list(arr)
  defp array_to_list(list) when is_list(list), do: list

  # ---------------------------------------------------------------------------
  # Private — encode: %ToolAd{} → plain map safe for Eden.encode/1
  # ---------------------------------------------------------------------------

  @spec ad_to_map(ToolAd.t()) :: map()
  defp ad_to_map(%ToolAd{} = ad) do
    %{
      id: ad.id,
      coordinate: ad.coordinate,
      kinds: Array.from_list(ad.kinds),
      binding: encode_binding(ad.binding),
      operational: ad.operational,
      constraint: ad.constraint,
      affordance: encode_affordance(ad.affordance),
      fidelity: ad.fidelity,
      provenance: encode_provenance(ad.provenance),
      lease: encode_lease(ad.lease)
    }
  end

  # `{:openai_chat, map}` → `Array` of `[:openai_chat, map]`
  @spec encode_binding({atom(), map()} | nil) :: Array.t() | nil
  defp encode_binding(nil), do: nil

  defp encode_binding({kind, payload}) do
    Array.from_list([kind, payload])
  end

  # `{:expires_at, DateTime.t()}` → `Array` of `[:expires_at, "ISO8601"]`
  @spec encode_lease(:permanent | {:expires_at, DateTime.t()}) :: atom() | Array.t()
  defp encode_lease(:permanent), do: :permanent

  defp encode_lease({:expires_at, %DateTime{} = dt}) do
    Array.from_list([:expires_at, DateTime.to_iso8601(dt)])
  end

  # `%{produced_at: DateTime.t(), ...}` → `%{produced_at: "ISO8601", ...}`
  @spec encode_provenance(map()) :: map()
  defp encode_provenance(p) when is_map(p) do
    Map.update!(p, :produced_at, &DateTime.to_iso8601/1)
  end

  # `%{declared: [...], learned: [...], ...}` → same with Array vectors
  @spec encode_affordance(map()) :: map()
  defp encode_affordance(a) when is_map(a) do
    a
    |> Map.update!(:declared, &Array.from_list/1)
    |> Map.update!(:learned, &Array.from_list/1)
  end
end

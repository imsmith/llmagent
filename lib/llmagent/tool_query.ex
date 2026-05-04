defmodule LLMAgent.ToolQuery do
  @moduledoc """
  Discovery query record and coordinate-matching helpers.

  A `%LLMAgent.ToolQuery{}` specifies what you are looking for in the discovery
  registry. It is the input to `LLMAgent.Tools.Discovery.find_one/1` and
  `LLMAgent.Tools.Discovery.find_all/1`. The registry matches ads against the
  query using `coordinate_matches?/2`, then filters by `kinds` and `fidelity_min`.

  Typical call sites are the dispatcher resolving a coordinate string to an ad,
  a supervisor pre-loading ads at startup, and test code verifying that specific
  ads are registered.

  See `docs/superpowers/specs/2026-05-03-tool-discovery-design.md` §2.

  ## Example

      alias LLMAgent.{ToolAd, ToolQuery, Tools.Discovery}

      # Build a query and ask discovery for a matching ad:
      q = ToolQuery.new(%{coordinate: "resource.network.*", kinds: [:query]})
      {:ok, ad} = Discovery.find_one(q)

      # Or use coordinate_matches?/2 directly for pattern testing:
      ToolQuery.coordinate_matches?("resource.network.*", "resource.network.netif")
      #=> true
  """

  @enforce_keys [:coordinate]
  defstruct [
    :coordinate,
    kinds: :any,
    fidelity_min: :speculative,
    constraint: nil,
    provenance: nil,
    limit: :all
  ]

  @typedoc """
  A discovery query.

  - `coordinate` — pattern to match against ad coordinates; supports trailing `.*`
    glob (see `coordinate_matches?/2`).
  - `kinds` — `:any` or a list of kind atoms that must ALL be present in the ad.
  - `fidelity_min` — minimum fidelity level; ads below this threshold are excluded.
  - `constraint` — reserved for constraint-aware matching (not evaluated in v1).
  - `provenance` — reserved for provenance-aware filtering (not evaluated in v1).
  - `limit` — `:all` or a positive integer to cap the result set.
  """
  @type t :: %__MODULE__{
          coordinate: String.t(),
          kinds: :any | [atom()],
          fidelity_min: :authoritative | :trained | :speculative,
          constraint: map() | nil,
          provenance: map() | nil,
          limit: pos_integer() | :all
        }

  @doc """
  Build a `%LLMAgent.ToolQuery{}` from a map of fields.

  Only `coordinate` is required. Defaults: `kinds: :any`, `fidelity_min: :speculative`,
  `limit: :all`.

  ## Examples

      iex> q = LLMAgent.ToolQuery.new(%{coordinate: "resource.network.*", kinds: [:query]})
      iex> {q.coordinate, q.kinds, q.fidelity_min}
      {"resource.network.*", [:query], :speculative}
  """
  @spec new(map()) :: t()
  def new(fields) when is_map(fields), do: struct!(__MODULE__, fields)

  @doc """
  Match a pattern against a coordinate.

  Pattern grammar (spec §2):

  - bare string: exact match
  - trailing `.*`: prefix match (matches the prefix itself, or prefix followed by `.<anything>`)
  - no other glob forms

  ## Examples

      iex> alias LLMAgent.ToolQuery
      iex> ToolQuery.coordinate_matches?("function.crypto.sha256", "function.crypto.sha256")
      true

      iex> alias LLMAgent.ToolQuery
      iex> ToolQuery.coordinate_matches?("resource.network.*", "resource.network.netif")
      true

      iex> alias LLMAgent.ToolQuery
      iex> ToolQuery.coordinate_matches?("resource.*.netif", "resource.network.netif")
      false
  """
  @spec coordinate_matches?(String.t(), String.t()) :: boolean()
  def coordinate_matches?(pattern, coordinate) when is_binary(pattern) and is_binary(coordinate) do
    cond do
      pattern == coordinate ->
        true

      String.ends_with?(pattern, ".*") ->
        prefix = String.trim_trailing(pattern, ".*")
        coordinate == prefix or String.starts_with?(coordinate, prefix <> ".")

      true ->
        false
    end
  end
end

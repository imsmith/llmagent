defmodule LLMAgent.ToolQuery do
  @moduledoc """
  Discovery query record and coordinate-matching helpers.

  See spec §2.
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

  @type t :: %__MODULE__{
          coordinate: String.t(),
          kinds: :any | [atom()],
          fidelity_min: :authoritative | :trained | :speculative,
          constraint: map() | nil,
          provenance: map() | nil,
          limit: pos_integer() | :all
        }

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

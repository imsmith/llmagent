defmodule LLMAgent.ToolAd do
  @moduledoc """
  A tool advertisement record. The single artifact in the discovery registry.

  See `docs/superpowers/specs/2026-05-03-tool-discovery-design.md` §1.
  """

  @enforce_keys [
    :id,
    :coordinate,
    :kinds,
    :binding,
    :operational,
    :constraint,
    :affordance,
    :fidelity,
    :provenance,
    :lease
  ]
  defstruct [
    :id,
    :coordinate,
    :kinds,
    :binding,
    :operational,
    :constraint,
    :affordance,
    :fidelity,
    :confidence,
    :provenance,
    :lease,
    meta: %{}
  ]

  @type binding_spec :: {atom(), term()} | nil

  @type t :: %__MODULE__{
          id: binary(),
          coordinate: String.t(),
          kinds: [atom()],
          binding: binding_spec(),
          operational: map(),
          constraint: map() | {:ref, String.t()},
          affordance: map(),
          fidelity: :authoritative | :trained | :speculative,
          confidence: float() | nil,
          provenance: map(),
          lease: :permanent | {:expires_at, DateTime.t()},
          meta: map()
        }

  @doc "Build a tool ad from a map. Raises if required fields are missing."
  @spec new(map()) :: t()
  def new(fields) when is_map(fields), do: struct!(__MODULE__, fields)
end

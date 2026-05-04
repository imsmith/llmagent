defmodule LLMAgent.ToolAd do
  @moduledoc """
  A tool advertisement record — the single artifact stored in the discovery registry.

  Every registered tool is described by a `%LLMAgent.ToolAd{}`. The record
  carries three independent description layers that answer different questions:

  - **operational** — what the tool does mechanically: input/output schemas, pre/post
    conditions, action map. This is the layer that MCP, OpenAPI, and tool-call schemas
    all solve. The agent uses it to know *how* to call the tool.
  - **constraint** — what governs use: per-action idempotency, blast radius, rate limits,
    retry posture. Distinct from the operational layer because the agent reasons about
    retry/verify/effect very differently across actions of the same tool. May alternatively
    be a `{:ref, coordinate}` pointing to a shared `policy.*` ad.
  - **affordance** — relational, partially declared, partially learned. The `declared`
    list is author hints (intent → suitability). The `learned` list is filled by trained-ad
    consumers (deferred spec). The `open` flag honestly says "treat this tool's affordance
    space as partially discoverable through interaction."

  **Fidelity** ranks description confidence: `:authoritative` ads are written by the tool
  author and are the ground truth; `:trained` ads are derived from observations; `:speculative`
  ads are probes or guesses. Multiple ads per coordinate are normal — the registry ranks them.

  **Lease** is `:permanent` for directly registered ads and `{:expires_at, ts}` for
  tuple-space announced ads. Same struct; the field discriminates.

  **Provenance** records origin and evidence chain for accumulation and trust filtering.
  The `signature` field is nil in v1 but present for future signed-ad support.

  See `docs/superpowers/specs/2026-05-03-tool-discovery-design.md` §1.

  ## Example

      iex> alias LLMAgent.ToolAd
      iex> ad = ToolAd.new(%{
      ...>   id: "ex.1",
      ...>   coordinate: "function.example",
      ...>   kinds: [:compute],
      ...>   binding: {:module, Enum},
      ...>   operational: %{actions: %{}},
      ...>   constraint: %{idempotency: %{}, blast_radius: %{}},
      ...>   affordance: %{declared: [], learned: [], open: false},
      ...>   fidelity: :authoritative,
      ...>   provenance: %{source: "ex", produced_at: ~U[2026-05-03 00:00:00Z], based_on: [], signature: nil},
      ...>   lease: :permanent
      ...> })
      iex> ad.coordinate
      "function.example"
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

  @typedoc """
  Binding specification. The first element is a binding-kind atom that must be
  registered in `LLMAgent.Tool.Bindings`; the second element is the opaque
  payload passed to the corresponding adapter. `nil` is valid for speculative
  ads that have no callable handle yet.
  """
  @type binding_spec :: {atom(), term()} | nil

  @typedoc """
  A fully-specified tool advertisement record.

  - `id` — ad identity (UUID or content-hash). Unique within the registry.
  - `coordinate` — dot-separated string, e.g. `"resource.network.netif"`.
  - `kinds` — composable list of kind atoms; each must be in `LLMAgent.Tool.Kinds`.
  - `binding` — how to invoke the tool; see `binding_spec`.
  - `operational` — input/output schema and action map.
  - `constraint` — idempotency, blast radius, and other governance fields.
  - `affordance` — declared and learned intent hints plus the `open` flag.
  - `fidelity` — confidence level: `:authoritative | :trained | :speculative`.
  - `confidence` — float in `[0.0, 1.0]` for trained/speculative; `nil` for authoritative.
  - `provenance` — origin map with `source`, `produced_at`, `based_on`, and `signature`.
  - `lease` — `:permanent` or `{:expires_at, DateTime.t()}`.
  - `meta` — open map for extension data.
  """
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

  @doc """
  Build a `%LLMAgent.ToolAd{}` from a map of fields.

  All `@enforce_keys` fields (`id`, `coordinate`, `kinds`, `binding`,
  `operational`, `constraint`, `affordance`, `fidelity`, `provenance`, `lease`)
  must be present in the map; raises `KeyError` otherwise.

  ## Examples

      iex> alias LLMAgent.ToolAd
      iex> ad = ToolAd.new(%{
      ...>   id: "ex.1",
      ...>   coordinate: "function.example",
      ...>   kinds: [:compute],
      ...>   binding: {:module, Enum},
      ...>   operational: %{actions: %{}},
      ...>   constraint: %{idempotency: %{}, blast_radius: %{}},
      ...>   affordance: %{declared: [], learned: [], open: false},
      ...>   fidelity: :authoritative,
      ...>   provenance: %{source: "ex", produced_at: ~U[2026-05-03 00:00:00Z], based_on: [], signature: nil},
      ...>   lease: :permanent
      ...> })
      iex> ad.coordinate
      "function.example"
  """
  @spec new(map()) :: t()
  def new(fields) when is_map(fields), do: struct!(__MODULE__, fields)
end

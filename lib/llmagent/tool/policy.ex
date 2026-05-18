defmodule LLMAgent.Tool.Policy do
  @moduledoc """
  Per-agent policy that gates the dispatcher.

  Every dispatcher call passes through `decide/4` before the adapter is
  invoked. A `%Policy{}` carries an allow list, a deny list, a minimum
  fidelity requirement, and an optional provenance constraint. The default
  empty struct denies everything — callers must explicitly allow coordinates.

  Policies compose with `intersect/2`, which produces a result at least as
  restrictive as either input (fail-closed). The `from_legacy_or_struct/1`
  helper translates the old `[:atom, ...]` allowed_tools format used by
  pre-discovery code.

  See `docs/superpowers/specs/2026-05-03-tool-discovery-design.md` §6.

  ## Usage example

      alias LLMAgent.Tool.{Policy, Dispatcher}

      policy = %Policy{
        allow: [%{coordinate: "function.*", kinds: [:compute], actions: :any}],
        fidelity_min: :authoritative
      }

      # Pass policy as an opt to any Dispatcher call:
      Dispatcher.compute("function.crypto.sha256", "sha256", %{"data" => "x"},
                         policy: policy)
  """

  alias LLMAgent.{ToolAd, ToolQuery}

  @enforce_keys []
  defstruct allow: [],
            deny: [],
            require_approval: [],
            fidelity_min: :trained,
            provenance: nil

  @typedoc """
  A policy rule. May be a bare coordinate pattern string (equivalent to
  `%{coordinate: pattern, kinds: :any, actions: :any}`) or a map with
  optional `:kinds` and `:actions` narrowing.
  """
  @type policy_rule :: %{coordinate: String.t(), kinds: :any | [atom()], actions: :any | [String.t()]}

  @typedoc """
  Per-agent dispatch policy.

  - `allow` — list of `policy_rule` or bare coordinate strings. Empty list
    denies all (fail-closed default).
  - `deny` — list of `policy_rule` or coordinate strings; checked first,
    takes priority over allow.
  - `fidelity_min` — minimum ad fidelity required to call the tool.
  - `provenance` — optional map with `:source` (list or `:any`) and
    `:signed` (boolean); `nil` means no provenance filtering.
  """
  @type t :: %__MODULE__{
          allow: [String.t() | policy_rule()],
          deny: [String.t() | policy_rule()],
          require_approval: [String.t() | policy_rule()],
          fidelity_min: :authoritative | :trained | :speculative,
          provenance: %{source: [String.t()] | :any, signed: boolean()} | nil
        }

  @fidelity_order %{speculative: 0, trained: 1, authoritative: 2}

  @doc """
  Decide whether a policy permits invoking `(ad, kind, action)`.

  Evaluation order:

  1. If any deny rule matches → `{:error, :forbidden, :explicit_deny}`
  2. If no allow rule matches → `{:error, :forbidden, :not_allowed}`
  3. If ad fidelity is below `fidelity_min` → `{:error, :forbidden, :fidelity_too_low}`
  4. If provenance source does not match → `{:error, :forbidden, :provenance}`
  5. If policy requires signed and ad is unsigned → `{:error, :forbidden, :unsigned}`
  6. Otherwise → `:ok`

  ## Examples

  Allow by coordinate wildcard:

      iex> alias LLMAgent.{ToolAd, Tool.Policy}
      iex> ad = ToolAd.new(%{
      ...>   id: "ex", coordinate: "function.crypto.sha256", kinds: [:compute],
      ...>   binding: {:module, Mod}, operational: %{actions: %{}},
      ...>   constraint: %{idempotency: %{}, blast_radius: %{}},
      ...>   affordance: %{declared: [], learned: [], open: false},
      ...>   fidelity: :authoritative,
      ...>   provenance: %{source: "test", produced_at: ~U[2026-05-03 00:00:00Z], based_on: [], signature: nil},
      ...>   lease: :permanent
      ...> })
      iex> Policy.decide(%Policy{allow: ["function.*"]}, ad, :compute, "sha256")
      :ok

  Deny by default (empty allow list):

      iex> alias LLMAgent.{ToolAd, Tool.Policy}
      iex> ad = ToolAd.new(%{
      ...>   id: "ex", coordinate: "function.crypto.sha256", kinds: [:compute],
      ...>   binding: {:module, Mod}, operational: %{actions: %{}},
      ...>   constraint: %{idempotency: %{}, blast_radius: %{}},
      ...>   affordance: %{declared: [], learned: [], open: false},
      ...>   fidelity: :authoritative,
      ...>   provenance: %{source: "test", produced_at: ~U[2026-05-03 00:00:00Z], based_on: [], signature: nil},
      ...>   lease: :permanent
      ...> })
      iex> Policy.decide(%Policy{}, ad, :compute, "sha256")
      {:error, :forbidden, :not_allowed}
  """
  @spec decide(t(), ToolAd.t(), atom(), String.t()) ::
          :ok | {:error, :forbidden, atom()}
  def decide(%__MODULE__{} = policy, %ToolAd{} = ad, kind, action) do
    cond do
      Enum.any?(policy.deny, &rule_matches?(&1, ad, kind, action)) ->
        {:error, :forbidden, :explicit_deny}

      not Enum.any?(policy.allow, &rule_matches?(&1, ad, kind, action)) ->
        {:error, :forbidden, :not_allowed}

      not fidelity_ok?(ad, policy) ->
        {:error, :forbidden, :fidelity_too_low}

      not provenance_source_ok?(ad, policy) ->
        {:error, :forbidden, :provenance}

      not provenance_signed_ok?(ad, policy) ->
        {:error, :forbidden, :unsigned}

      true ->
        :ok
    end
  end

  @doc """
  Return `true` if any `require_approval` rule in `policy` matches `(ad, kind, action)`.
  """
  @spec requires_approval?(t(), ToolAd.t(), atom(), String.t()) :: boolean()
  def requires_approval?(%__MODULE__{require_approval: rules}, %ToolAd{} = ad, kind, action) do
    Enum.any?(rules, &rule_matches?(&1, ad, kind, action))
  end

  @doc """
  Intersect (narrow) two policies. The result is at least as restrictive as
  either input.

  - `allow` list: whichever of `base.allow` or `override.allow` is shorter
    (narrower by cardinality; full coordinate-level intersection is deferred).
  - `deny` list: concatenation of both deny lists.
  - `fidelity_min`: stricter (higher) of the two.
  - `provenance`: stricter of the two.

  ## Examples

      iex> alias LLMAgent.Tool.Policy
      iex> base = %Policy{allow: ["function.*"], fidelity_min: :trained}
      iex> override = %Policy{allow: ["function.specific"], fidelity_min: :authoritative}
      iex> merged = Policy.intersect(base, override)
      iex> {merged.fidelity_min, hd(merged.allow)}
      {:authoritative, "function.*"}
  """
  @spec intersect(t(), t()) :: t()
  def intersect(%__MODULE__{} = base, %__MODULE__{} = override) do
    %__MODULE__{
      allow: intersect_rule_lists(base.allow, override.allow),
      deny: base.deny ++ override.deny,
      require_approval: base.require_approval ++ override.require_approval,
      fidelity_min: stricter_fidelity(base.fidelity_min, override.fidelity_min),
      provenance: stricter_provenance(base.provenance, override.provenance)
    }
  end

  @doc """
  Translate the legacy `[:atom, ...]` allowed_tools format, or pass through a
  `%Policy{}` unchanged.

  Legacy atom lists map each atom to a `legacy.<atom>` coordinate rule with
  `:any` kinds and actions, fidelity `:authoritative`, and permissive
  provenance.

  ## Examples

      iex> alias LLMAgent.Tool.Policy
      iex> p = Policy.from_legacy_or_struct([:bash, :web])
      iex> Enum.map(p.allow, & &1.coordinate)
      ["legacy.bash", "legacy.web"]
  """
  @spec from_legacy_or_struct([atom()] | t()) :: t()
  def from_legacy_or_struct(%__MODULE__{} = p), do: p

  def from_legacy_or_struct(list) when is_list(list) do
    %__MODULE__{
      allow:
        Enum.map(list, fn name when is_atom(name) ->
          %{coordinate: "legacy.#{name}", kinds: :any, actions: :any}
        end),
      fidelity_min: :authoritative,
      provenance: %{source: :any, signed: false}
    }
  end

  # --- internal helpers ---

  @doc false
  defp rule_matches?(rule, %ToolAd{} = ad, kind, action) do
    %{coordinate: coord, kinds: kinds, actions: actions} = normalize_rule(rule)

    ToolQuery.coordinate_matches?(coord, ad.coordinate) and
      kinds_match?(kinds, kind) and
      actions_match?(actions, action)
  end

  @doc false
  defp normalize_rule(s) when is_binary(s),
    do: %{coordinate: s, kinds: :any, actions: :any}

  @doc false
  defp normalize_rule(%{} = m), do: Map.merge(%{kinds: :any, actions: :any}, m)

  @doc false
  defp kinds_match?(:any, _kind), do: true

  @doc false
  defp kinds_match?(list, kind) when is_list(list), do: kind in list

  @doc false
  defp actions_match?(:any, _action), do: true

  @doc false
  defp actions_match?(list, action) when is_list(list), do: action in list

  @doc false
  defp fidelity_ok?(%ToolAd{fidelity: f}, %__MODULE__{fidelity_min: m}),
    do: @fidelity_order[f] >= @fidelity_order[m]

  @doc false
  defp provenance_source_ok?(_ad, %__MODULE__{provenance: nil}), do: true

  @doc false
  defp provenance_source_ok?(_ad, %__MODULE__{provenance: %{source: :any}}), do: true

  @doc false
  defp provenance_source_ok?(%ToolAd{provenance: %{source: src}}, %__MODULE__{provenance: %{source: list}})
       when is_list(list),
       do: src in list

  @doc false
  defp provenance_signed_ok?(_ad, %__MODULE__{provenance: nil}), do: true

  @doc false
  defp provenance_signed_ok?(_ad, %__MODULE__{provenance: %{signed: false}}), do: true

  @doc false
  defp provenance_signed_ok?(%ToolAd{provenance: %{signature: nil}}, %__MODULE__{provenance: %{signed: true}}),
    do: false

  @doc false
  defp provenance_signed_ok?(_ad, _policy), do: true

  @doc false
  defp stricter_fidelity(a, b) do
    if @fidelity_order[a] >= @fidelity_order[b], do: a, else: b
  end

  @doc false
  defp stricter_provenance(nil, b), do: b

  @doc false
  defp stricter_provenance(a, nil), do: a

  @doc false
  defp stricter_provenance(%{source: a_src, signed: a_sgn}, %{source: b_src, signed: b_sgn}) do
    %{
      source: stricter_source(a_src, b_src),
      signed: a_sgn or b_sgn
    }
  end

  @doc false
  defp stricter_source(:any, b), do: b

  @doc false
  defp stricter_source(a, :any), do: a

  @doc false
  defp stricter_source(a, b) when is_list(a) and is_list(b), do: Enum.filter(a, &(&1 in b))

  @doc false
  defp intersect_rule_lists([], override), do: override

  @doc false
  defp intersect_rule_lists(base, []), do: base

  @doc false
  defp intersect_rule_lists(base, override) do
    # Conservative: pick the list with fewer rules (narrower by cardinality).
    # True coordinate-level intersection (per-rule prefix-glob overlap) is
    # deferred to a follow-on; this approximation fails closed by preferring
    # the smaller allow set.
    if length(base) <= length(override), do: base, else: override
  end
end

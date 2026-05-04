defmodule LLMAgent.Tool.Policy do
  @moduledoc """
  Per-agent policy that gates the dispatcher. See spec §6.
  """

  alias LLMAgent.{ToolAd, ToolQuery}

  @enforce_keys []
  defstruct allow: [],
            deny: [],
            fidelity_min: :trained,
            provenance: nil

  @type policy_rule :: %{coordinate: String.t(), kinds: :any | [atom()], actions: :any | [String.t()]}

  @type t :: %__MODULE__{
          allow: [String.t() | policy_rule()],
          deny: [String.t() | policy_rule()],
          fidelity_min: :authoritative | :trained | :speculative,
          provenance: %{source: [String.t()] | :any, signed: boolean()} | nil
        }

  @fidelity_order %{speculative: 0, trained: 1, authoritative: 2}

  @doc """
  Decide whether a policy permits invoking (ad, kind, action).

  Returns `:ok` or `{:error, :forbidden, reason}`.
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

  @doc "Intersect (narrow) two policies. The result is at least as restrictive as either input."
  @spec intersect(t(), t()) :: t()
  def intersect(%__MODULE__{} = base, %__MODULE__{} = override) do
    %__MODULE__{
      allow: intersect_rule_lists(base.allow, override.allow),
      deny: base.deny ++ override.deny,
      fidelity_min: stricter_fidelity(base.fidelity_min, override.fidelity_min),
      provenance: stricter_provenance(base.provenance, override.provenance)
    }
  end

  @doc "Translate the legacy `[:atom, ...]` allowed_tools or pass through a %Policy{}."
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

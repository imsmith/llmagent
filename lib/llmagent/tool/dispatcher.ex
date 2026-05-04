defmodule LLMAgent.Tool.Dispatcher do
  @moduledoc """
  Single entry point for invoking tools. Resolves coordinates → ads,
  enforces policy, checks kinds, looks up binding adapters, dispatches.
  Emits telemetry on every call. See spec §4.3.
  """

  alias LLMAgent.{ToolAd, ToolQuery, Tool.Bindings, Tool.Policy, Tools.Discovery}

  @type result :: term()
  @type opts :: keyword()

  @doc "Query a tool without side effects."
  @spec query(ToolAd.t() | String.t(), String.t(), map(), opts()) :: result()
  def query(ad_or_coord, action, args, opts \\ []),
    do: dispatch(ad_or_coord, :query, action, args, opts)

  @doc "Invoke a tool with side effects and optional idempotency."
  @spec act(ToolAd.t() | String.t(), String.t(), map(), String.t() | nil, opts()) :: result()
  def act(ad_or_coord, action, args, idempotency_key \\ nil, opts \\ []) do
    dispatch(ad_or_coord, :action, action, args, [{:idempotency_key, idempotency_key} | opts])
  end

  @doc "Subscribe to streaming results from a tool."
  @spec subscribe(ToolAd.t() | String.t(), String.t(), map(), pid(), opts()) :: result()
  def subscribe(ad_or_coord, action, args, subscriber, opts \\ []),
    do: dispatch(ad_or_coord, :stream, action, args, [{:subscriber, subscriber} | opts])

  @doc "Compute a deterministic result via a compute-kind tool."
  @spec compute(ToolAd.t() | String.t(), String.t(), map(), opts()) :: result()
  def compute(ad_or_coord, action, args, opts \\ []),
    do: dispatch(ad_or_coord, :compute, action, args, opts)

  @doc "Participate in coordination via a coordinate-kind tool."
  @spec participate(ToolAd.t() | String.t(), atom(), map(), opts()) :: result()
  def participate(ad_or_coord, role, args, opts \\ []),
    do: dispatch(ad_or_coord, :coordinate, role, args, opts)

  @doc "Spawn a child process via a spawn-kind tool."
  @spec spawn_child(ToolAd.t() | String.t(), term(), opts()) :: result()
  def spawn_child(ad_or_coord, spec, opts \\ []),
    do: dispatch(ad_or_coord, :spawn, spec, %{}, opts)

  # --- core dispatch ---

  defp dispatch(ad_or_coord, kind, action_or_role_or_spec, args, opts) do
    with {:ok, ad} <- resolve(ad_or_coord),
         policy = Keyword.get(opts, :policy, %Policy{}),
         action_str = action_to_string(action_or_role_or_spec),
         :ok <- Policy.decide(policy, ad, kind, action_str),
         :ok <- check_kind(ad, kind),
         {:ok, adapter, payload} <- resolve_adapter(ad) do
      result = invoke(adapter, kind, payload, action_or_role_or_spec, args, opts)

      :telemetry.execute(
        [:llmagent, :tool, kind],
        %{},
        %{
          coordinate: ad.coordinate,
          action: action_str,
          fidelity: ad.fidelity,
          provenance_source: get_in(ad.provenance, [:source])
        }
      )

      result
    else
      {:error, _} = err -> err
      {:error, _, _} = err -> err
    end
  end

  defp resolve(%ToolAd{} = ad), do: {:ok, ad}

  defp resolve(coordinate) when is_binary(coordinate) do
    case Discovery.find_one(ToolQuery.new(%{coordinate: coordinate})) do
      {:ok, ad} -> {:ok, ad}
      {:error, :not_found} = err -> err
    end
  end

  defp check_kind(%ToolAd{kinds: kinds}, kind) do
    if kind in kinds, do: :ok, else: {:error, :kind_not_supported}
  end

  defp resolve_adapter(%ToolAd{binding: {binding_kind, payload}}) do
    case Bindings.adapter_for(binding_kind) do
      {:ok, adapter} -> {:ok, adapter, payload}
      {:error, :not_found} -> {:error, :binding_not_supported}
    end
  end

  defp resolve_adapter(%ToolAd{binding: nil}), do: {:error, :binding_not_supported}

  defp action_to_string(s) when is_binary(s), do: s
  defp action_to_string(a) when is_atom(a), do: Atom.to_string(a)
  defp action_to_string(other), do: inspect(other)

  defp invoke(adapter, :query, payload, action, args, opts),
    do: adapter.query(payload, action, args, opts)

  defp invoke(adapter, :action, payload, action, args, opts) do
    key = Keyword.get(opts, :idempotency_key)
    adapter.act(payload, action, args, key, Keyword.delete(opts, :idempotency_key))
  end

  defp invoke(adapter, :stream, payload, action, args, opts) do
    subscriber = Keyword.fetch!(opts, :subscriber)
    adapter.subscribe(payload, action, args, subscriber, Keyword.delete(opts, :subscriber))
  end

  defp invoke(adapter, :compute, payload, action, args, opts),
    do: adapter.compute(payload, action, args, opts)

  defp invoke(adapter, :coordinate, payload, role, args, opts),
    do: adapter.participate(payload, role, args, opts)

  defp invoke(adapter, :spawn, payload, spec, _args, opts),
    do: adapter.spawn_child(payload, spec, opts)
end

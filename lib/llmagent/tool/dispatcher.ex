defmodule LLMAgent.Tool.Dispatcher do
  @moduledoc """
  Single entry point for invoking tools. Resolves coordinates to ads,
  enforces policy, checks kind support, looks up binding adapters, dispatches,
  and emits telemetry on every call.

  The dispatch pipeline for every call:

  1. **Resolve** — if given a coordinate string, calls `Discovery.find_one/1`
     to get the top-ranked matching `ToolAd`. If given a `%ToolAd{}` directly,
     uses it as-is.
  2. **Policy** — calls `Policy.decide/4` with the ad, kind, and action.
     Default policy (empty `%Policy{}`) denies all; callers must pass an
     `:policy` opt or use a permissive policy.
  3. **Kind check** — verifies the ad declares the requested kind.
  4. **Adapter** — looks up the binding adapter via `Bindings.adapter_for/1`.
  5. **Invoke** — delegates to the adapter's kind-specific callback.
  6. **Telemetry** — emits `[:llmagent, :tool, kind]` with coordinate, action,
     fidelity, and provenance source.

  See `docs/superpowers/specs/2026-05-03-tool-discovery-design.md` §4.3.

  > No doctests — all dispatch paths depend on live registry and process state.
  > See `test/llmagent/tools/discovery_test.exs` for integration-level examples.

  ## End-to-end example

  ```elixir
  alias LLMAgent.{ToolAd, ToolQuery, Tool.Policy, Tool.Dispatcher, Tools.Discovery}

  # Register a compute tool:
  ad = ToolAd.new(%{
    id: "hash.1", coordinate: "function.crypto.sha256", kinds: [:compute],
    binding: {:module, MyHasher},
    operational: %{actions: %{}}, constraint: %{idempotency: %{}, blast_radius: %{}},
    affordance: %{declared: [], learned: [], open: false}, fidelity: :authoritative,
    provenance: %{source: "my_app", produced_at: DateTime.utc_now(),
                  based_on: [], signature: nil},
    lease: :permanent
  })
  :ok = Discovery.register(ad)

  # Dispatch with an explicit allow policy:
  policy = %Policy{allow: ["function.crypto.*"], fidelity_min: :authoritative}
  {:ok, digest} = Dispatcher.compute("function.crypto.sha256", "sha256",
                                     %{"data" => "hello"}, policy: policy)
  ```
  """

  alias LLMAgent.{ToolAd, ToolQuery, Tool.Bindings, Tool.Policy, Tools.Discovery}

  @type result :: term()
  @type opts :: keyword()

  @doc """
  Query a tool without side effects.

  Dispatches via the `:query` kind. The ad must declare `:query` in its
  `kinds` list and its binding adapter must implement `query/4`.

  Pass `:policy` in `opts` to enforce access control; default denies all.
  """
  @spec query(ToolAd.t() | String.t(), String.t(), map(), opts()) :: result()
  def query(ad_or_coord, action, args, opts \\ []),
    do: dispatch(ad_or_coord, :query, action, args, opts)

  @doc """
  Invoke a tool with side effects and optional idempotency.

  Dispatches via the `:action` kind. Pass `idempotency_key` (a unique string
  per logical operation) to allow the adapter to suppress duplicate effects on
  retry.
  """
  @spec act(ToolAd.t() | String.t(), String.t(), map(), String.t() | nil, opts()) :: result()
  def act(ad_or_coord, action, args, idempotency_key \\ nil, opts \\ []) do
    dispatch(ad_or_coord, :action, action, args, [{:idempotency_key, idempotency_key} | opts])
  end

  @doc """
  Subscribe to streaming results from a tool.

  Dispatches via the `:stream` kind. Returns `{:ok, sub_ref}` on success.
  The `subscriber` pid receives messages from the tool process until
  `unsubscribe/2` is called (via the adapter directly).
  """
  @spec subscribe(ToolAd.t() | String.t(), String.t(), map(), pid(), opts()) :: result()
  def subscribe(ad_or_coord, action, args, subscriber, opts \\ []),
    do: dispatch(ad_or_coord, :stream, action, args, [{:subscriber, subscriber} | opts])

  @doc """
  Compute a deterministic result via a compute-kind tool.

  Dispatches via the `:compute` kind. The ad must be a pure-compute tool;
  no side effects, freely retryable.
  """
  @spec compute(ToolAd.t() | String.t(), String.t(), map(), opts()) :: result()
  def compute(ad_or_coord, action, args, opts \\ []),
    do: dispatch(ad_or_coord, :compute, action, args, opts)

  @doc """
  Produce a stochastic output via a generate-kind tool.

  Dispatches via the `:generate` kind. The ad must declare `:generate` in its
  `kinds` list and its binding adapter must implement `generate/4`.

  Unlike `:compute`, results are not expected to be deterministic — the same
  inputs may yield different outputs (e.g. LLM completions, image generation).
  Safely retryable but must not be cached by input hash. Returns
  `{:ok, value, provenance}` on success where `provenance` carries model id,
  latency, token counts, and any other adapter-specific observations.
  """
  @spec generate(ToolAd.t() | String.t(), String.t(), map(), opts()) :: result()
  def generate(ad_or_coord, action, args, opts \\ []),
    do: dispatch(ad_or_coord, :generate, action, args, opts)

  @doc """
  Participate in coordination via a coordinate-kind tool.

  Dispatches via the `:coordinate` kind. `role` is an atom passed to the
  adapter's `participate/4` callback.
  """
  @spec participate(ToolAd.t() | String.t(), atom(), map(), opts()) :: result()
  def participate(ad_or_coord, role, args, opts \\ []),
    do: dispatch(ad_or_coord, :coordinate, role, args, opts)

  @doc """
  Spawn a child process via a spawn-kind tool.

  Dispatches via the `:spawn` kind. `spec` is passed opaquely to the
  adapter's `spawn_child/3` callback. Returns `{:ok, child_ref}` on success.
  """
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

  defp invoke(adapter, :generate, payload, action, args, opts),
    do: adapter.generate(payload, action, args, opts)

  defp invoke(adapter, :coordinate, payload, role, args, opts),
    do: adapter.participate(payload, role, args, opts)

  defp invoke(adapter, :spawn, payload, spec, _args, opts),
    do: adapter.spawn_child(payload, spec, opts)
end

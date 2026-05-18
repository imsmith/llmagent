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

  alias LLMAgent.{Events, ToolAd, ToolQuery, Tool.Bindings, Tool.Policy, Tools.Discovery}

  @type result :: term()
  @type opts :: keyword()

  @pending_table :llmagent_pending_approvals

  @doc """
  Create the ETS table that tracks pending approvals. Called once at boot.
  """
  @spec init_approvals() :: :ok
  def init_approvals do
    if :ets.whereis(@pending_table) == :undefined do
      :ets.new(@pending_table, [:set, :public, :named_table])
    end

    :ok
  end

  @doc """
  Request human (or programmatic) approval before invoking a tool.

  Emits a `tool.pending_approval` event carrying an opaque `id`, the resolved
  ad's coordinate and kinds, and the proposed `action`/`args`. Blocks the
  calling process until `approve/2` is called with the same id, or until
  `:timeout` (default `:infinity`) elapses.

  Returns `:allow`, `:deny`, or `{:error, :timeout | :not_found}`.

  ## Options

    * `:action` — string or atom describing the proposed action (default `nil`)
    * `:args`   — map of arguments to surface to the approver (default `%{}`)
    * `:timeout` — milliseconds to wait, or `:infinity` (default `:infinity`)
  """
  @spec request_approval(ToolAd.t() | String.t(), opts()) ::
          :allow | :deny | {:error, :timeout | :not_found}
  def request_approval(ad_or_coord, opts \\ []) do
    init_approvals()
    id = generate_id()
    :ets.insert(@pending_table, {id, self()})

    summary =
      case resolve(ad_or_coord) do
        {:ok, ad} -> %{coordinate: ad.coordinate, kinds: ad.kinds}
        _ -> %{coordinate: inspect(ad_or_coord), kinds: []}
      end

    data =
      summary
      |> Map.put(:id, id)
      |> Map.put(:action, opts |> Keyword.get(:action) |> stringify())
      |> Map.put(:args, Keyword.get(opts, :args, %{}))

    Events.emit(:pending_approval, "tool.pending_approval", data, __MODULE__)

    timeout = Keyword.get(opts, :timeout, :infinity)

    receive do
      {:approval, ^id, decision} ->
        :ets.delete(@pending_table, id)
        decision
    after
      timeout ->
        :ets.delete(@pending_table, id)
        {:error, :timeout}
    end
  end

  @doc """
  Deliver an approval decision to the process awaiting `id`.

  `decision` must be `:allow` or `:deny`. Returns `:ok` on delivery,
  `{:error, :not_found}` if the id is unknown or already resolved.
  """
  @spec approve(String.t(), :allow | :deny) :: :ok | {:error, :not_found}
  def approve(id, decision) when decision in [:allow, :deny] do
    case :ets.lookup(@pending_table, id) do
      [{^id, pid}] ->
        send(pid, {:approval, id, decision})
        :ok

      [] ->
        {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  defp generate_id, do: "appr_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))

  defp stringify(nil), do: nil
  defp stringify(a) when is_atom(a), do: Atom.to_string(a)
  defp stringify(s) when is_binary(s), do: s
  defp stringify(other), do: inspect(other)

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
         :ok <- maybe_request_approval(policy, ad, kind, action_str, args, opts),
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

  defp maybe_request_approval(policy, ad, kind, action_str, args, opts) do
    if Policy.requires_approval?(policy, ad, kind, action_str) do
      approval_opts =
        opts
        |> Keyword.take([:approval_timeout])
        |> Keyword.put(:action, action_str)
        |> Keyword.put(:args, args)
        |> rename_key(:approval_timeout, :timeout)

      case request_approval(ad, approval_opts) do
        :allow -> :ok
        :deny -> {:error, :forbidden, :user_denied}
        {:error, :timeout} -> {:error, :forbidden, :approval_timeout}
      end
    else
      :ok
    end
  end

  defp rename_key(kw, from, to) do
    case Keyword.pop(kw, from) do
      {nil, kw} -> kw
      {v, kw} -> Keyword.put(kw, to, v)
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

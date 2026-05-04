defmodule LLMAgent.Tools.Discovery do
  @moduledoc """
  Tool discovery registry. Stores `LLMAgent.ToolAd` records and serves
  pattern-matching queries. See spec §2 and §5.

  This module is built up across plan tasks 9–14. Task 9 adds register / update
  / unregister / renew / find_one / find_all with ranking.

  Storage: ETS table owned by this GenServer, keyed by ad_id.
  """

  use GenServer

  alias LLMAgent.{ToolAd, ToolQuery}

  @table :llmagent_tool_discovery
  @fidelity_order %{authoritative: 2, trained: 1, speculative: 0}
  @announce_space :tool_announce

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Reset the discovery table for testing."
  @spec reset!() :: :ok
  def reset!, do: GenServer.call(__MODULE__, :reset)

  @doc "Register a new tool ad. Returns error if id already exists."
  @spec register(ToolAd.t()) :: :ok | {:error, term()}
  def register(%ToolAd{} = ad), do: GenServer.call(__MODULE__, {:register, ad})

  @doc "Update an existing tool ad (no duplicate-id check)."
  @spec update(ToolAd.t()) :: :ok | {:error, term()}
  def update(%ToolAd{} = ad), do: GenServer.call(__MODULE__, {:update, ad})

  @doc "Unregister a tool ad by id."
  @spec unregister(binary()) :: :ok
  def unregister(ad_id) when is_binary(ad_id),
    do: GenServer.call(__MODULE__, {:unregister, ad_id})

  @doc "Renew (extend) the lease of a tool ad."
  @spec renew(binary(), DateTime.t()) :: :ok | {:error, :not_found}
  def renew(ad_id, %DateTime{} = expires_at),
    do: GenServer.call(__MODULE__, {:renew, ad_id, expires_at})

  @doc "Subscribe to tool discovery events matching a query."
  @spec subscribe(ToolQuery.t(), pid()) :: :ok
  def subscribe(%ToolQuery{} = q, subscriber) when is_pid(subscriber),
    do: GenServer.call(__MODULE__, {:subscribe, q, subscriber})

  @doc "Synchronously sweep expired leases (primarily for tests)."
  @spec sweep_now() :: :ok
  def sweep_now, do: GenServer.call(__MODULE__, :sweep_now)

  @doc "Find the top-ranked tool ad matching the query."
  @spec find_one(ToolQuery.t()) :: {:ok, ToolAd.t()} | {:error, :not_found}
  def find_one(%ToolQuery{} = q) do
    case find_all(q) do
      {:ok, [first | _]} -> {:ok, first}
      {:ok, []} -> {:error, :not_found}
    end
  end

  @doc "Find all tool ads matching the query, ranked by fidelity/confidence/recency."
  @spec find_all(ToolQuery.t()) :: {:ok, [ToolAd.t()]}
  def find_all(%ToolQuery{} = q) do
    ads =
      :ets.tab2list(@table)
      |> Enum.map(fn {_id, ad} -> ad end)
      |> Enum.filter(&matches?(&1, q))
      |> Enum.sort_by(&rank_key/1)
      |> apply_limit(q.limit)

    {:ok, ads}
  end

  # --- Validation (used by register/update; will also be used by §5.2 announcement consumer) ---

  @doc "Validate a tool ad structure. Returns :ok or {:error, {:invalid_ad, field, reason}}."
  @spec validate(ToolAd.t()) :: :ok | {:error, {:invalid_ad, atom(), String.t()}}
  def validate(%ToolAd{} = ad) do
    cond do
      not (is_binary(ad.coordinate) and String.contains?(ad.coordinate, ".") and ad.coordinate != "") ->
        {:error, {:invalid_ad, :coordinate, "must be non-empty dotted string"}}

      not (is_list(ad.kinds) and ad.kinds != [] and Enum.all?(ad.kinds, &is_atom/1)) ->
        {:error, {:invalid_ad, :kinds, "must be non-empty list of atoms"}}

      not valid_fidelity?(ad.fidelity) ->
        {:error, {:invalid_ad, :fidelity, "must be :authoritative | :trained | :speculative"}}

      not valid_lease?(ad.lease) ->
        {:error, {:invalid_ad, :lease, "must be :permanent or {:expires_at, future DateTime}"}}

      not valid_provenance?(ad.provenance) ->
        {:error, {:invalid_ad, :provenance, "must include :source and :produced_at"}}

      true ->
        :ok
    end
  end

  defp valid_fidelity?(f), do: f in [:authoritative, :trained, :speculative]
  defp valid_lease?(:permanent), do: true
  defp valid_lease?({:expires_at, %DateTime{}}), do: true
  defp valid_lease?(_), do: false

  defp valid_provenance?(%{source: src, produced_at: %DateTime{}}) when not is_nil(src), do: true
  defp valid_provenance?(_), do: false

  # --- GenServer ---

  @impl true
  def init(opts) do
    table =
      :ets.new(@table, [
        :set,
        :protected,
        :named_table,
        read_concurrency: true
      ])

    interval = Keyword.get(opts, :sweep_interval_ms, 30_000)
    schedule_sweep(interval)

    consume_announcements? = Keyword.get(opts, :consume_announcements, true)
    if consume_announcements?, do: schedule_announce_poll()

    {:ok,
     %{
       table: table,
       subscribers: %{},
       sweep_interval_ms: interval,
       consume_announcements: consume_announcements?
     }}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  def handle_call(:sweep_now, _from, state) do
    do_sweep(state)
    {:reply, :ok, state}
  end

  def handle_call({:subscribe, query, pid}, _from, state) do
    monitor_ref = Process.monitor(pid)
    subs = Map.put(state.subscribers, monitor_ref, {pid, query})
    {:reply, :ok, %{state | subscribers: subs}}
  end

  def handle_call({:register, ad}, _from, state) do
    cond do
      :ets.member(@table, ad.id) ->
        {:reply, {:error, :duplicate_id}, state}

      true ->
        case validate(ad) do
          :ok ->
            :ets.insert(@table, {ad.id, ad})
            notify_subscribers(state.subscribers, ad, :tool_added)
            {:reply, :ok, state}

          {:error, _} = err ->
            {:reply, err, state}
        end
    end
  end

  def handle_call({:update, ad}, _from, state) do
    case validate(ad) do
      :ok ->
        :ets.insert(@table, {ad.id, ad})
        notify_subscribers(state.subscribers, ad, :tool_updated)
        {:reply, :ok, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:unregister, ad_id}, _from, state) do
    case :ets.lookup(@table, ad_id) do
      [{^ad_id, ad}] ->
        :ets.delete(@table, ad_id)
        notify_subscribers_removed(state.subscribers, ad, :unregistered)

      [] ->
        :ok
    end

    {:reply, :ok, state}
  end

  def handle_call({:renew, ad_id, expires_at}, _from, state) do
    case :ets.lookup(@table, ad_id) do
      [{^ad_id, ad}] ->
        :ets.insert(@table, {ad_id, %{ad | lease: {:expires_at, expires_at}}})
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}
  end

  def handle_info(:sweep, state) do
    do_sweep(state)
    schedule_sweep(state.sweep_interval_ms)
    {:noreply, state}
  end

  def handle_info(:poll_announcements, state) do
    drain_announcements(state)

    if state.consume_announcements,
      do: schedule_announce_poll()

    {:noreply, state}
  end

  # --- Matching / ranking ---

  defp matches?(%ToolAd{} = ad, %ToolQuery{} = q) do
    ToolQuery.coordinate_matches?(q.coordinate, ad.coordinate) and
      kinds_ok?(q.kinds, ad.kinds) and
      fidelity_ok?(q.fidelity_min, ad.fidelity)
  end

  defp kinds_ok?(:any, _ad_kinds), do: true
  defp kinds_ok?(required, ad_kinds) when is_list(required),
    do: Enum.all?(required, &(&1 in ad_kinds))

  defp fidelity_ok?(min, ad_fid) do
    @fidelity_order[ad_fid] >= @fidelity_order[min]
  end

  defp rank_key(%ToolAd{fidelity: f, confidence: c, provenance: %{produced_at: t}}) do
    # Higher fidelity first → invert. Then higher confidence → invert. Then more recent.
    {-(@fidelity_order[f] || 0), -(c || 0.0), -DateTime.to_unix(t, :microsecond)}
  end

  defp apply_limit(list, :all), do: list
  defp apply_limit(list, n) when is_integer(n) and n > 0, do: Enum.take(list, n)

  defp notify_subscribers(subs, %ToolAd{} = ad, event) do
    for {_ref, {pid, query}} <- subs, matches?(ad, query) do
      send(pid, {event, ad.id, ad.coordinate})
    end

    :ok
  end

  defp notify_subscribers_removed(subs, %ToolAd{} = ad, reason) do
    for {_ref, {pid, query}} <- subs, matches?(ad, query) do
      send(pid, {:tool_removed, ad.id, ad.coordinate, reason})
    end

    :ok
  end

  defp do_sweep(state) do
    now = DateTime.utc_now()

    expired =
      :ets.tab2list(@table)
      |> Enum.flat_map(fn
        {_id, %ToolAd{lease: {:expires_at, ts}} = ad} ->
          if DateTime.compare(ts, now) == :lt, do: [ad], else: []

        _ ->
          []
      end)

    for ad <- expired do
      :ets.delete(@table, ad.id)
      notify_subscribers_removed(state.subscribers, ad, :lease_expired)
    end

    :ok
  end

  # --- Announcement Consumer ---

  defp drain_announcements(state) do
    case ensure_announce_space() do
      :ok ->
        drain_loop(state)

      {:error, _} ->
        :ok
    end
  end

  defp drain_loop(state) do
    case LLMAgent.TupleSpace.in_nowait(@announce_space, {:tool_announce, :_, :_}) do
      {:ok, {:tool_announce, _id, %ToolAd{} = ad}} ->
        absorb_announcement(state, ad)
        drain_loop(state)

      {:ok, _other} ->
        # Malformed; drop
        drain_loop(state)

      {:error, :no_match} ->
        drain_withdrawals(state)

      {:error, _} ->
        :ok
    end
  end

  defp drain_withdrawals(state) do
    case LLMAgent.TupleSpace.in_nowait(@announce_space, {:tool_withdraw, :_}) do
      {:ok, {:tool_withdraw, ad_id}} when is_binary(ad_id) ->
        case :ets.lookup(@table, ad_id) do
          [{^ad_id, ad}] ->
            :ets.delete(@table, ad_id)
            notify_subscribers_removed(state.subscribers, ad, :unregistered)

          [] ->
            :ok
        end

        drain_withdrawals(state)

      {:ok, _other} ->
        drain_withdrawals(state)

      {:error, :no_match} ->
        :ok

      {:error, _} ->
        :ok
    end
  end

  defp absorb_announcement(state, %ToolAd{} = ad) do
    case validate(ad) do
      :ok ->
        existed? = :ets.member(@table, ad.id)
        :ets.insert(@table, {ad.id, ad})

        event = if existed?, do: :tool_updated, else: :tool_added
        notify_subscribers(state.subscribers, ad, event)

      {:error, _} ->
        :ok
    end
  end

  defp ensure_announce_space do
    case LLMAgent.TupleSpace.list_spaces() do
      spaces when is_list(spaces) ->
        if @announce_space in spaces, do: :ok, else: ensure_started()

      _ ->
        {:error, :tuple_space_unavailable}
    end
  rescue
    RuntimeError -> {:error, :tuple_space_unavailable}
  end

  defp ensure_started do
    case LLMAgent.TupleSpace.start_space(@announce_space) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      other -> other
    end
  end

  defp schedule_announce_poll,
    do: Process.send_after(self(), :poll_announcements, 100)

  defp schedule_sweep(interval) when is_integer(interval) and interval > 0,
    do: Process.send_after(self(), :sweep, interval)

  defp schedule_sweep(_), do: :ok
end

defmodule LLMAgent.TupleSpace.Space do
  @moduledoc """
  GenServer managing a single named tuple space.

  Owns an ETS duplicate_bag table for tuple storage. Serializes
  mutations (out, in_) through the GenServer. Non-destructive reads
  (rd_nowait) can bypass the GenServer and read ETS directly.

  Registered in `LLMAgent.TupleSpace.Registry` by name.
  """

  use GenServer
  require Logger

  alias LLMAgent.TupleSpace.Pattern
  alias LLMAgent.Events

  @doc """
  Start a space GenServer linked to the calling process.

  ## Options

    * `:name` (required) — atom identifying the space, used for Registry lookup and ETS table naming

  ## Examples

      iex> name = :"doctest_space_#{System.unique_integer([:positive])}"
      iex> {:ok, pid} = LLMAgent.TupleSpace.Space.start_link(name: name)
      iex> is_pid(pid)
      true
      iex> GenServer.stop(pid)
      :ok
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  ## Public API — non-blocking

  @doc "Write a tuple into the space (async)."
  @spec out(pid(), tuple()) :: :ok
  def out(pid, tuple) when is_tuple(tuple) do
    GenServer.cast(pid, {:out, tuple})
    :ok
  end

  @doc "Take a matching tuple from the space (non-blocking). Returns {:ok, tuple} or {:error, :no_match}."
  @spec in_nowait(pid(), tuple()) :: {:ok, tuple()} | {:error, :no_match | :invalid_pattern}
  def in_nowait(pid, pattern) do
    case Pattern.compile(pattern) do
      {:ok, _spec} -> GenServer.call(pid, {:in_nowait, pattern})
      {:error, _} = err -> err
    end
  end

  @doc "Read a matching tuple from the space without removing it (non-blocking, direct ETS)."
  @spec rd_nowait(pid(), tuple()) :: {:ok, tuple()} | {:error, :no_match | :invalid_pattern}
  def rd_nowait(pid, pattern) do
    case Pattern.compile(pattern) do
      {:ok, spec} ->
        table = GenServer.call(pid, :table_name)
        match_pattern = spec |> hd() |> elem(0)

        case :ets.match_object(table, match_pattern) do
          [first | _] -> {:ok, first}
          [] -> {:error, :no_match}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc "Blocking destructive read. Blocks until a match or timeout (ms)."
  def in_(pid, pattern, timeout) do
    case Pattern.compile(pattern) do
      {:ok, _spec} -> GenServer.call(pid, {:in_, pattern, timeout}, :infinity)
      {:error, _} = err -> err
    end
  end

  @doc "Blocking non-destructive read. Blocks until a match or timeout (ms)."
  def rd(pid, pattern, timeout) do
    case Pattern.compile(pattern) do
      {:ok, _spec} -> GenServer.call(pid, {:rd, pattern, timeout}, :infinity)
      {:error, _} = err -> err
    end
  end

  @doc "Return metadata about this space."
  @spec info(pid()) :: map()
  def info(pid), do: GenServer.call(pid, :info)

  @doc "Return the ETS table name for this space."
  @spec table_name(pid()) :: atom()
  def table_name(pid), do: GenServer.call(pid, :table_name)

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    table = :"llmagent_ts_#{name}"
    :ets.new(table, [:duplicate_bag, :public, :named_table])

    Events.emit(:lifecycle, "tuple_space.created", %{space: name}, __MODULE__)

    {:ok, %{name: name, table: table, waiters: []}}
  end

  @impl true
  def handle_cast({:out, tuple}, state) do
    :ets.insert(state.table, tuple)

    {woken, remaining_waiters} = dispatch_waiters(tuple, state)

    Events.emit(:out, "tuple_space.out", %{
      space: state.name,
      tuple: tuple,
      waiters_woken: woken
    }, __MODULE__)

    {:noreply, %{state | waiters: remaining_waiters}}
  end

  @impl true
  def handle_call({:in_nowait, pattern}, _from, state) do
    {:ok, spec} = Pattern.compile(pattern)
    match_pattern = spec |> hd() |> elem(0)

    case :ets.match_object(state.table, match_pattern) do
      [first | _] ->
        consume_one(state.table, first)

        Events.emit(:in, "tuple_space.in", %{
          space: state.name,
          tuple: first
        }, __MODULE__)

        {:reply, {:ok, first}, state}

      [] ->
        {:reply, {:error, :no_match}, state}
    end
  end

  def handle_call({:in_, pattern, timeout}, from, state) do
    {:ok, spec} = Pattern.compile(pattern)
    match_pattern = spec |> hd() |> elem(0)

    case :ets.match_object(state.table, match_pattern) do
      [first | _] ->
        consume_one(state.table, first)

        Events.emit(:in, "tuple_space.in", %{
          space: state.name,
          tuple: first
        }, __MODULE__)

        {:reply, {:ok, first}, state}

      [] when timeout == 0 ->
        {:reply, {:error, :timeout}, state}

      [] ->
        waiter = add_waiter(from, pattern, :in_, timeout)
        {:noreply, %{state | waiters: state.waiters ++ [waiter]}}
    end
  end

  def handle_call({:rd, pattern, timeout}, from, state) do
    {:ok, spec} = Pattern.compile(pattern)
    match_pattern = spec |> hd() |> elem(0)

    case :ets.match_object(state.table, match_pattern) do
      [first | _] ->
        {:reply, {:ok, first}, state}

      [] when timeout == 0 ->
        {:reply, {:error, :timeout}, state}

      [] ->
        waiter = add_waiter(from, pattern, :rd, timeout)
        {:noreply, %{state | waiters: state.waiters ++ [waiter]}}
    end
  end

  def handle_call(:table_name, _from, state) do
    {:reply, state.table, state}
  end

  def handle_call(:info, _from, state) do
    info = %{
      name: state.name,
      size: :ets.info(state.table, :size),
      waiters: length(state.waiters)
    }

    {:reply, info, state}
  end

  @impl true
  def handle_info({:waiter_timeout, ref}, state) do
    case Enum.find(state.waiters, fn w -> w.timer_ref == ref end) do
      nil ->
        {:noreply, state}

      waiter ->
        GenServer.reply(waiter.from, {:error, :timeout})
        Process.demonitor(waiter.monitor, [:flush])
        {:noreply, %{state | waiters: List.delete(state.waiters, waiter)}}
    end
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Enum.find(state.waiters, fn w -> w.monitor == monitor_ref end) do
      nil ->
        {:noreply, state}

      waiter ->
        Process.cancel_timer(waiter.timer)
        {:noreply, %{state | waiters: List.delete(state.waiters, waiter)}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Events.emit(:lifecycle, "tuple_space.destroyed", %{space: state.name}, __MODULE__)
    :ok
  end

  ## Private helpers

  defp add_waiter(from, pattern, operation, timeout) do
    {caller_pid, _} = from
    ref = make_ref()
    timer = Process.send_after(self(), {:waiter_timeout, ref}, timeout)
    monitor = Process.monitor(caller_pid)

    %{
      from: from,
      pattern: pattern,
      operation: operation,
      timer: timer,
      timer_ref: ref,
      monitor: monitor
    }
  end

  defp dispatch_waiters(tuple, state) do
    {matching_in, rest_after_in} = find_first_matching(state.waiters, tuple, :in_)

    case matching_in do
      nil ->
        {matching_rds, remaining} = find_all_matching(state.waiters, tuple, :rd)

        Enum.each(matching_rds, fn waiter ->
          GenServer.reply(waiter.from, {:ok, tuple})
          Process.cancel_timer(waiter.timer)
          Process.demonitor(waiter.monitor, [:flush])
        end)

        {length(matching_rds), remaining}

      waiter ->
        # in_ waiter wins — consume one copy of the tuple from ETS
        consume_one(state.table, tuple)
        GenServer.reply(waiter.from, {:ok, tuple})
        Process.cancel_timer(waiter.timer)
        Process.demonitor(waiter.monitor, [:flush])

        Events.emit(:in, "tuple_space.in", %{
          space: state.name,
          tuple: tuple
        }, __MODULE__)

        {1, rest_after_in}
    end
  end

  defp find_first_matching(waiters, tuple, operation) do
    case Enum.split_while(waiters, fn w ->
           w.operation != operation or not Pattern.match?(w.pattern, tuple)
         end) do
      {before, [match | after_match]} -> {match, before ++ after_match}
      {_all, []} -> {nil, waiters}
    end
  end

  defp find_all_matching(waiters, tuple, operation) do
    Enum.split_with(waiters, fn w ->
      w.operation == operation and Pattern.match?(w.pattern, tuple)
    end)
  end

  defp consume_one(table, tuple) do
    # duplicate_bag: delete_object removes ALL identical copies.
    # Count them first, delete all, reinsert (count - 1).
    all_copies = :ets.match_object(table, tuple)
    :ets.delete_object(table, tuple)
    duplicates = length(all_copies) - 1
    Enum.each(1..duplicates//1, fn _ -> :ets.insert(table, tuple) end)
  end

  defp via(name), do: {:via, Registry, {LLMAgent.TupleSpace.Registry, name}}
end

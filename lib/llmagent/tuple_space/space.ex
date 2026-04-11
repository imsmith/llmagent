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
      [first | rest] ->
        # duplicate_bag: delete_object removes ALL identical copies.
        # Delete all, then reinsert the extras so only one is consumed.
        :ets.delete_object(state.table, first)
        duplicates = Enum.count(rest, fn t -> t == first end)
        Enum.each(1..duplicates//1, fn _ -> :ets.insert(state.table, first) end)

        Events.emit(:in, "tuple_space.in", %{
          space: state.name,
          tuple: first
        }, __MODULE__)

        {:reply, {:ok, first}, state}

      [] ->
        {:reply, {:error, :no_match}, state}
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
  def terminate(_reason, state) do
    Events.emit(:lifecycle, "tuple_space.destroyed", %{space: state.name}, __MODULE__)
    :ok
  end

  ## Private — stub for Task 3

  defp dispatch_waiters(_tuple, state) do
    {0, state.waiters}
  end

  defp via(name), do: {:via, Registry, {LLMAgent.TupleSpace.Registry, name}}
end

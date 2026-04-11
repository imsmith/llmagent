# Tuple Space Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a Linda-style tuple space for multi-agent coordination, backed by ETS with GenServer-managed blocking operations and pattern matching.

**Architecture:** One GenServer per named space under a DynamicSupervisor. ETS duplicate_bag tables for storage. Pattern module compiles `:_` wildcard tuples to ETS match specs. Deferred GenServer replies for blocking in_/rd. Facade module routes operations.

**Tech Stack:** Elixir, GenServer, ETS, DynamicSupervisor, Registry, LLMAgent.Events, Comn.Errors.ErrorStruct

---

## File Structure

```
lib/llmagent/tuple_space/
  pattern.ex           # Compiles Elixir patterns to ETS match specs, element-wise match?
  space.ex             # GenServer per named space — owns ETS, manages waiters, deferred replies
  tuple_space.ex       # Public facade — space management + Linda operations

test/tuple_space/
  pattern_test.exs     # Pattern compilation and matching tests
  space_test.exs       # Space GenServer unit tests (blocking, waiters, priority)
  tuple_space_test.exs # Facade + integration tests

lib/llmagent/application.ex  # Modified — add Registry + DynamicSupervisor + :default space
```

---

### Task 1: Pattern Module

**Files:**
- Create: `test/tuple_space/pattern_test.exs`
- Create: `lib/llmagent/tuple_space/pattern.ex`

- [ ] **Step 1: Write failing tests for Pattern**

```elixir
defmodule LLMAgent.TupleSpace.PatternTest do
  use ExUnit.Case, async: true

  alias LLMAgent.TupleSpace.Pattern

  describe "compile/1" do
    test "compiles a tuple with no wildcards" do
      {:ok, spec} = Pattern.compile({:task, :pending, "build"})
      assert is_list(spec)
      assert length(spec) == 1
    end

    test "compiles a tuple with :_ wildcards" do
      {:ok, spec} = Pattern.compile({:task, :_, :_})
      assert is_list(spec)
    end

    test "compiles a single-element tuple" do
      {:ok, spec} = Pattern.compile({:ping})
      assert is_list(spec)
    end

    test "returns error for non-tuple input" do
      assert {:error, :invalid_pattern} = Pattern.compile("not a tuple")
      assert {:error, :invalid_pattern} = Pattern.compile(42)
      assert {:error, :invalid_pattern} = Pattern.compile([:a, :b])
      assert {:error, :invalid_pattern} = Pattern.compile(%{a: 1})
    end
  end

  describe "match?/2" do
    test "exact match" do
      assert Pattern.match?({:task, :pending, "build"}, {:task, :pending, "build"})
    end

    test "wildcard matches any value" do
      assert Pattern.match?({:task, :pending, :_}, {:task, :pending, "build"})
      assert Pattern.match?({:task, :pending, :_}, {:task, :pending, 42})
    end

    test "multiple wildcards" do
      assert Pattern.match?({:task, :_, :_}, {:task, :pending, "build"})
    end

    test "all wildcards" do
      assert Pattern.match?({:_, :_, :_}, {:task, :pending, "build"})
    end

    test "mismatch on literal" do
      refute Pattern.match?({:task, :done, :_}, {:task, :pending, "build"})
    end

    test "mismatch on tuple size" do
      refute Pattern.match?({:task, :pending}, {:task, :pending, "build"})
      refute Pattern.match?({:task, :pending, :_, :_}, {:task, :pending, "build"})
    end

    test "single-element tuples" do
      assert Pattern.match?({:ping}, {:ping})
      refute Pattern.match?({:ping}, {:pong})
    end
  end

  describe "compile/1 works with ETS match_object" do
    setup do
      table = :ets.new(:pattern_test, [:duplicate_bag, :public])
      :ets.insert(table, {:task, :pending, "build"})
      :ets.insert(table, {:task, :done, "deploy"})
      :ets.insert(table, {:result, 42})
      on_exit(fn -> :ets.delete(table) end)
      %{table: table}
    end

    test "finds matching tuples via compiled spec", %{table: table} do
      {:ok, spec} = Pattern.compile({:task, :pending, :_})
      results = :ets.match_object(table, spec |> hd() |> elem(0))
      assert results == [{:task, :pending, "build"}]
    end

    test "wildcard matches multiple", %{table: table} do
      {:ok, spec} = Pattern.compile({:task, :_, :_})
      results = :ets.match_object(table, spec |> hd() |> elem(0))
      assert length(results) == 2
    end

    test "no match returns empty", %{table: table} do
      {:ok, spec} = Pattern.compile({:nothing, :here})
      results = :ets.match_object(table, spec |> hd() |> elem(0))
      assert results == []
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/tuple_space/pattern_test.exs`
Expected: compilation error — `LLMAgent.TupleSpace.Pattern` not defined

- [ ] **Step 3: Implement Pattern module**

```elixir
defmodule LLMAgent.TupleSpace.Pattern do
  @moduledoc """
  Compiles Elixir-friendly tuple patterns into ETS match specs.

  Patterns are tuples where `:_` matches any value in that position
  and all other values are literal matches.

  ## Examples

      iex> {:ok, spec} = LLMAgent.TupleSpace.Pattern.compile({:task, :pending, :_})
      iex> is_list(spec)
      true

      iex> LLMAgent.TupleSpace.Pattern.compile("not a tuple")
      {:error, :invalid_pattern}

      iex> LLMAgent.TupleSpace.Pattern.match?({:task, :_, :_}, {:task, :pending, "build"})
      true

      iex> LLMAgent.TupleSpace.Pattern.match?({:task, :done, :_}, {:task, :pending, "build"})
      false
  """

  @doc """
  Compile a tuple pattern into an ETS match spec.

  Returns `{:ok, match_spec}` or `{:error, :invalid_pattern}`.
  The match spec can be passed to `:ets.match_object/2` — use the
  first element of the first spec tuple as the match pattern.
  """
  @spec compile(tuple()) :: {:ok, list()} | {:error, :invalid_pattern}
  def compile(pattern) when is_tuple(pattern) do
    {:ok, [{pattern, [], [:"$_"]}]}
  end

  def compile(_), do: {:error, :invalid_pattern}

  @doc """
  Test if a concrete tuple matches a pattern.

  Used by the Space GenServer to check waiters against newly written
  tuples without going back to ETS.
  """
  @spec match?(pattern :: tuple(), tuple :: tuple()) :: boolean()
  def match?(pattern, tuple) when is_tuple(pattern) and is_tuple(tuple) do
    if tuple_size(pattern) != tuple_size(tuple) do
      false
    else
      pattern_list = Tuple.to_list(pattern)
      tuple_list = Tuple.to_list(tuple)

      Enum.zip(pattern_list, tuple_list)
      |> Enum.all?(fn
        {:_, _} -> true
        {a, b} -> a == b
      end)
    end
  end

  def match?(_, _), do: false
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/tuple_space/pattern_test.exs`
Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/tuple_space/pattern.ex test/tuple_space/pattern_test.exs
git commit -m "Add tuple space pattern matching module"
```

---

### Task 2: Space GenServer — Core Operations (out, in_nowait, rd via ETS)

**Files:**
- Create: `test/tuple_space/space_test.exs`
- Create: `lib/llmagent/tuple_space/space.ex`

This task implements the GenServer with non-blocking operations only. Blocking (deferred reply) is added in Task 3.

- [ ] **Step 1: Write failing tests for Space (non-blocking operations)**

```elixir
defmodule LLMAgent.TupleSpace.SpaceTest do
  use ExUnit.Case, async: false

  alias LLMAgent.TupleSpace.Space

  setup do
    name = :"test_space_#{System.unique_integer([:positive])}"
    {:ok, pid} = Space.start_link(name: name)
    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)
    %{pid: pid, name: name}
  end

  describe "out + in_nowait" do
    test "write and take a tuple", %{pid: pid} do
      :ok = Space.out(pid, {:task, :pending, "build"})
      assert {:ok, {:task, :pending, "build"}} = Space.in_nowait(pid, {:task, :pending, :_})
    end

    test "in_nowait removes the tuple", %{pid: pid} do
      :ok = Space.out(pid, {:task, :pending, "build"})
      {:ok, _} = Space.in_nowait(pid, {:task, :pending, :_})
      assert {:error, :no_match} = Space.in_nowait(pid, {:task, :pending, :_})
    end

    test "in_nowait returns no_match when empty", %{pid: pid} do
      assert {:error, :no_match} = Space.in_nowait(pid, {:task, :_, :_})
    end

    test "multiple tuples, pattern selects correctly", %{pid: pid} do
      :ok = Space.out(pid, {:task, :pending, "build"})
      :ok = Space.out(pid, {:task, :done, "deploy"})
      assert {:ok, {:task, :pending, "build"}} = Space.in_nowait(pid, {:task, :pending, :_})
      assert {:ok, {:task, :done, "deploy"}} = Space.in_nowait(pid, {:task, :done, :_})
    end

    test "duplicate tuples allowed", %{pid: pid} do
      :ok = Space.out(pid, {:task, :pending, "build"})
      :ok = Space.out(pid, {:task, :pending, "build"})
      {:ok, _} = Space.in_nowait(pid, {:task, :pending, :_})
      # Second copy still there
      {:ok, _} = Space.in_nowait(pid, {:task, :pending, :_})
      # Now empty
      assert {:error, :no_match} = Space.in_nowait(pid, {:task, :pending, :_})
    end
  end

  describe "rd_nowait (direct ETS)" do
    test "reads without removing", %{pid: pid} do
      :ok = Space.out(pid, {:task, :pending, "build"})
      assert {:ok, {:task, :pending, "build"}} = Space.rd_nowait(pid, {:task, :pending, :_})
      # Still there
      assert {:ok, {:task, :pending, "build"}} = Space.rd_nowait(pid, {:task, :pending, :_})
    end

    test "returns no_match when empty", %{pid: pid} do
      assert {:error, :no_match} = Space.rd_nowait(pid, {:task, :_, :_})
    end
  end

  describe "invalid patterns" do
    test "in_nowait rejects non-tuple", %{pid: pid} do
      assert {:error, :invalid_pattern} = Space.in_nowait(pid, "not a tuple")
    end

    test "rd_nowait rejects non-tuple", %{pid: pid} do
      assert {:error, :invalid_pattern} = Space.rd_nowait(pid, "not a tuple")
    end
  end

  describe "info" do
    test "returns space metadata", %{pid: pid, name: name} do
      :ok = Space.out(pid, {:a, 1})
      :ok = Space.out(pid, {:b, 2})
      info = Space.info(pid)
      assert info.name == name
      assert info.size == 2
      assert info.waiters == 0
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/tuple_space/space_test.exs`
Expected: compilation error — `LLMAgent.TupleSpace.Space` not defined

- [ ] **Step 3: Implement Space GenServer (non-blocking operations)**

```elixir
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
  alias Comn.Errors.ErrorStruct

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  ## Public API — non-blocking

  @doc "Write a tuple into the space. Async (cast)."
  def out(pid, tuple) when is_tuple(tuple) do
    GenServer.cast(pid, {:out, tuple})
    :ok
  end

  @doc "Non-blocking destructive read. Returns `{:ok, tuple}` or `{:error, :no_match}`."
  def in_nowait(pid, pattern) do
    case Pattern.compile(pattern) do
      {:ok, _spec} -> GenServer.call(pid, {:in_nowait, pattern})
      {:error, _} = err -> err
    end
  end

  @doc "Non-blocking non-destructive read. Bypasses the GenServer — reads ETS directly."
  def rd_nowait(pid, pattern) do
    case Pattern.compile(pattern) do
      {:ok, spec} ->
        table = GenServer.call(pid, :table_name)
        match_pattern = spec |> hd() |> elem(0)
        case :ets.match_object(table, match_pattern) do
          [first | _] -> {:ok, first}
          [] -> {:error, :no_match}
        end
      {:error, _} = err -> err
    end
  end

  @doc "Return space metadata."
  def info(pid), do: GenServer.call(pid, :info)

  @doc "Return the ETS table name for this space."
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
        :ets.delete_object(state.table, first)

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

  ## Private — Waiter Dispatch (stub for Task 3)

  defp dispatch_waiters(_tuple, state) do
    {0, state.waiters}
  end

  defp via(name), do: {:via, Registry, {LLMAgent.TupleSpace.Registry, name}}
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/tuple_space/space_test.exs`
Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/tuple_space/space.ex test/tuple_space/space_test.exs
git commit -m "Add tuple space GenServer with non-blocking operations"
```

---

### Task 3: Space GenServer — Blocking Operations & Waiter Management

**Files:**
- Modify: `test/tuple_space/space_test.exs`
- Modify: `lib/llmagent/tuple_space/space.ex`

Add blocking `in_/3` and `rd/3` with deferred replies, waiter timeout, waiter process monitoring, and waiter priority dispatch (in_ beats rd).

- [ ] **Step 1: Add blocking operation tests to space_test.exs**

Append these describes to the existing test file:

```elixir
  describe "blocking in_" do
    test "blocks until a matching tuple arrives", %{pid: pid} do
      # Write after a short delay
      Task.start(fn ->
        Process.sleep(50)
        Space.out(pid, {:task, :pending, "delayed"})
      end)

      # This blocks until the out above fires
      assert {:ok, {:task, :pending, "delayed"}} = Space.in_(pid, {:task, :pending, :_}, 1_000)
    end

    test "returns immediately if match exists", %{pid: pid} do
      Space.out(pid, {:task, :pending, "ready"})
      assert {:ok, {:task, :pending, "ready"}} = Space.in_(pid, {:task, :pending, :_}, 1_000)
    end

    test "times out when no match arrives", %{pid: pid} do
      assert {:error, :timeout} = Space.in_(pid, {:task, :pending, :_}, 50)
    end

    test "timeout 0 is equivalent to nowait", %{pid: pid} do
      assert {:error, :timeout} = Space.in_(pid, {:task, :pending, :_}, 0)
    end

    test "removes the tuple on match", %{pid: pid} do
      Task.start(fn ->
        Process.sleep(50)
        Space.out(pid, {:task, :pending, "take_me"})
      end)

      {:ok, _} = Space.in_(pid, {:task, :pending, :_}, 1_000)
      assert {:error, :no_match} = Space.in_nowait(pid, {:task, :pending, :_})
    end
  end

  describe "blocking rd" do
    test "blocks until a matching tuple arrives (non-destructive)", %{pid: pid} do
      Task.start(fn ->
        Process.sleep(50)
        Space.out(pid, {:result, 42})
      end)

      assert {:ok, {:result, 42}} = Space.rd(pid, {:result, :_}, 1_000)
      # Still there — rd is non-destructive
      assert {:ok, {:result, 42}} = Space.rd_nowait(pid, {:result, :_})
    end

    test "times out when no match arrives", %{pid: pid} do
      assert {:error, :timeout} = Space.rd(pid, {:result, :_}, 50)
    end
  end

  describe "waiter priority" do
    test "in_ waiter takes precedence over rd waiter", %{pid: pid} do
      # Start an in_ waiter and an rd waiter
      in_task = Task.async(fn -> Space.in_(pid, {:prize, :_}, 1_000) end)
      Process.sleep(10)
      rd_task = Task.async(fn -> Space.rd(pid, {:prize, :_}, 1_000) end)
      Process.sleep(10)

      # Write the tuple — in_ waiter should get it and remove it
      Space.out(pid, {:prize, "gold"})

      assert {:ok, {:prize, "gold"}} = Task.await(in_task)
      # rd waiter should timeout because in_ took the tuple
      assert {:error, :timeout} = Task.await(rd_task)
    end
  end

  describe "waiter cleanup on caller death" do
    test "removes waiter when caller dies", %{pid: pid} do
      # Start a process that blocks on in_, then kill it
      {caller, ref} = spawn_monitor(fn ->
        Space.in_(pid, {:never, :_}, 60_000)
      end)
      Process.sleep(20)

      # Verify waiter is registered
      assert Space.info(pid).waiters == 1

      # Kill the caller
      Process.exit(caller, :kill)
      receive do: ({:DOWN, ^ref, :process, _, _} -> :ok)
      Process.sleep(20)

      # Waiter should be cleaned up
      assert Space.info(pid).waiters == 0
    end
  end
```

- [ ] **Step 2: Run tests to verify new tests fail**

Run: `mix test test/tuple_space/space_test.exs`
Expected: failures on blocking operations — `in_/3` and `rd/3` not defined

- [ ] **Step 3: Add public API for blocking operations to Space**

Add to the public API section of `lib/llmagent/tuple_space/space.ex`:

```elixir
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
```

- [ ] **Step 4: Add handle_call clauses for blocking operations**

Add to GenServer callbacks in `lib/llmagent/tuple_space/space.ex`:

```elixir
  def handle_call({:in_, pattern, timeout}, from, state) do
    {:ok, spec} = Pattern.compile(pattern)
    match_pattern = spec |> hd() |> elem(0)

    case :ets.match_object(state.table, match_pattern) do
      [first | _] ->
        :ets.delete_object(state.table, first)

        Events.emit(:in, "tuple_space.in", %{
          space: state.name,
          tuple: first
        }, __MODULE__)

        {:reply, {:ok, first}, state}

      [] ->
        if timeout == 0 do
          {:reply, {:error, :timeout}, state}
        else
          waiter = add_waiter(from, pattern, :in_, timeout)
          {:noreply, %{state | waiters: state.waiters ++ [waiter]}}
        end
    end
  end

  def handle_call({:rd, pattern, timeout}, from, state) do
    {:ok, spec} = Pattern.compile(pattern)
    match_pattern = spec |> hd() |> elem(0)

    case :ets.match_object(state.table, match_pattern) do
      [first | _] ->
        {:reply, {:ok, first}, state}

      [] ->
        if timeout == 0 do
          {:reply, {:error, :timeout}, state}
        else
          waiter = add_waiter(from, pattern, :rd, timeout)
          {:noreply, %{state | waiters: state.waiters ++ [waiter]}}
        end
    end
  end
```

- [ ] **Step 5: Add waiter management helpers and handle_info clauses**

Replace the `dispatch_waiters` stub and add new private functions and handle_info clauses:

```elixir
  @impl true
  def handle_info({:waiter_timeout, timer_ref}, state) do
    case Enum.find(state.waiters, fn w -> w.timer == timer_ref end) do
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

  ## Private — Waiter Management

  defp add_waiter(from, pattern, operation, timeout) do
    {caller_pid, _} = from
    timer = Process.send_after(self(), {:waiter_timeout, make_ref()}, timeout)
    monitor = Process.monitor(caller_pid)

    # Use the timer ref as the unique waiter identifier
    %{
      from: from,
      pattern: pattern,
      operation: operation,
      timer: timer,
      monitor: monitor
    }
  end

  defp dispatch_waiters(tuple, state) do
    {matching_in, rest_after_in} = find_first_matching(state.waiters, tuple, :in_)

    case matching_in do
      nil ->
        # No in_ waiter — notify all matching rd waiters
        {matching_rds, remaining} = find_all_matching(state.waiters, tuple, :rd)

        Enum.each(matching_rds, fn waiter ->
          GenServer.reply(waiter.from, {:ok, tuple})
          Process.cancel_timer(waiter.timer)
          Process.demonitor(waiter.monitor, [:flush])
        end)

        {length(matching_rds), remaining}

      waiter ->
        # in_ waiter wins — take the tuple, remove from ETS
        :ets.delete_object(state.table, tuple)
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
```

**Note on timer ref:** The `add_waiter` function creates a unique ref via `make_ref()` and passes it to `Process.send_after`. However, `Process.send_after` returns a timer reference, not the ref we passed. Fix: use the timer ref returned by `Process.send_after` directly as the waiter's identifier:

```elixir
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
```

And update `handle_info` to match on `timer_ref`:

```elixir
  def handle_info({:waiter_timeout, ref}, state) do
    case Enum.find(state.waiters, fn w -> w.timer_ref == ref end) do
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/tuple_space/space_test.exs`
Expected: all tests pass

- [ ] **Step 7: Commit**

```bash
git add lib/llmagent/tuple_space/space.ex test/tuple_space/space_test.exs
git commit -m "Add blocking operations and waiter management to tuple space"
```

---

### Task 4: Facade & Supervision Wiring

**Files:**
- Create: `test/tuple_space/tuple_space_test.exs`
- Create: `lib/llmagent/tuple_space/tuple_space.ex`
- Modify: `lib/llmagent/application.ex`

- [ ] **Step 1: Wire supervision tree**

Add to `lib/llmagent/application.ex` children list, after the MCP entries:

```elixir
      {Registry, keys: :unique, name: LLMAgent.TupleSpace.Registry},
      {DynamicSupervisor, name: LLMAgent.TupleSpace.Supervisor, strategy: :one_for_one}
```

And after the `LLMAgent.AgentSupervisor.start_agent(agent_opts)` line, start the default space:

```elixir
    LLMAgent.TupleSpace.start_space(:default)
```

(This requires the facade to exist — implement it next before testing.)

- [ ] **Step 2: Write failing tests for the facade**

```elixir
defmodule LLMAgent.TupleSpaceTest do
  use ExUnit.Case, async: false

  alias LLMAgent.TupleSpace

  describe "space management" do
    test "start and stop a named space" do
      {:ok, pid} = TupleSpace.start_space(:test_mgmt)
      assert is_pid(pid)
      assert :test_mgmt in TupleSpace.list_spaces()
      assert :ok = TupleSpace.stop_space(:test_mgmt)
      refute :test_mgmt in TupleSpace.list_spaces()
    end

    test "duplicate space returns already_started" do
      {:ok, _} = TupleSpace.start_space(:test_dup)
      assert {:error, {:already_started, _}} = TupleSpace.start_space(:test_dup)
      TupleSpace.stop_space(:test_dup)
    end

    test "stop nonexistent space returns error" do
      assert {:error, :not_found} = TupleSpace.stop_space(:nonexistent_ts)
    end

    test "default space exists on boot" do
      assert :default in TupleSpace.list_spaces()
    end
  end

  describe "Linda operations on default space" do
    setup do
      # Clear default space by restarting it
      TupleSpace.stop_space(:default)
      {:ok, _} = TupleSpace.start_space(:default)
      :ok
    end

    test "out and in_nowait" do
      :ok = TupleSpace.out({:test, "value"})
      assert {:ok, {:test, "value"}} = TupleSpace.in_nowait({:test, :_})
    end

    test "out and rd_nowait" do
      :ok = TupleSpace.out({:test, "value"})
      assert {:ok, {:test, "value"}} = TupleSpace.rd_nowait({:test, :_})
      # Still there
      assert {:ok, {:test, "value"}} = TupleSpace.rd_nowait({:test, :_})
    end

    test "blocking in_ with delayed out" do
      Task.start(fn ->
        Process.sleep(50)
        TupleSpace.out({:delayed, "arrived"})
      end)

      assert {:ok, {:delayed, "arrived"}} = TupleSpace.in_({:delayed, :_}, 1_000)
    end

    test "blocking rd with delayed out" do
      Task.start(fn ->
        Process.sleep(50)
        TupleSpace.out({:delayed, "peek"})
      end)

      assert {:ok, {:delayed, "peek"}} = TupleSpace.rd({:delayed, :_}, 1_000)
    end
  end

  describe "Linda operations on named space" do
    setup do
      {:ok, _} = TupleSpace.start_space(:named_test)
      on_exit(fn ->
        try do
          TupleSpace.stop_space(:named_test)
        catch
          _, _ -> :ok
        end
      end)
      :ok
    end

    test "out and in_nowait on named space" do
      :ok = TupleSpace.out(:named_test, {:task, "build"})
      assert {:ok, {:task, "build"}} = TupleSpace.in_nowait(:named_test, {:task, :_})
    end

    test "blocking operations on named space" do
      Task.start(fn ->
        Process.sleep(50)
        TupleSpace.out(:named_test, {:result, 42})
      end)

      assert {:ok, {:result, 42}} = TupleSpace.in_(:named_test, {:result, :_}, 1_000)
    end
  end

  describe "error handling" do
    test "operations on nonexistent space" do
      assert {:error, :space_not_found} = TupleSpace.out(:nonexistent_ts, {:a, 1})
      assert {:error, :space_not_found} = TupleSpace.in_nowait(:nonexistent_ts, {:a, :_})
      assert {:error, :space_not_found} = TupleSpace.in_(:nonexistent_ts, {:a, :_}, 100)
      assert {:error, :space_not_found} = TupleSpace.rd(:nonexistent_ts, {:a, :_}, 100)
    end

    test "rd_nowait on nonexistent space" do
      assert {:error, :space_not_found} = TupleSpace.rd_nowait(:nonexistent_ts, {:a, :_})
    end

    test "invalid pattern" do
      assert {:error, :invalid_pattern} = TupleSpace.in_nowait("not a tuple")
      assert {:error, :invalid_pattern} = TupleSpace.rd_nowait("not a tuple")
    end
  end
end
```

- [ ] **Step 3: Implement the facade**

```elixir
defmodule LLMAgent.TupleSpace do
  @moduledoc """
  Public API for Linda-style tuple space coordination.

  Provides `out` (write), `in_` (blocking destructive read), `rd` (blocking
  non-destructive read), and non-blocking variants. Operations default to
  the `:default` space; pass a space name as the first argument for others.

  ## Examples

      iex> :ok = LLMAgent.TupleSpace.out({:greeting, "hello"})
      iex> {:ok, {:greeting, "hello"}} = LLMAgent.TupleSpace.in_nowait({:greeting, :_})
  """

  alias LLMAgent.TupleSpace.{Space, Pattern}

  ## Space Management

  @doc "Start a new named tuple space."
  def start_space(name) do
    DynamicSupervisor.start_child(
      LLMAgent.TupleSpace.Supervisor,
      {Space, name: name}
    )
  end

  @doc "Stop a named tuple space. Unregisters and destroys ETS table."
  def stop_space(name) do
    case lookup(name) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(LLMAgent.TupleSpace.Supervisor, pid)
      {:error, _} = err -> err
    end
  end

  @doc "List all active space names."
  def list_spaces do
    LLMAgent.TupleSpace.Supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn {_, pid, _, _} ->
      if is_pid(pid) do
        try do
          [Space.info(pid).name]
        catch
          :exit, _ -> []
        end
      else
        []
      end
    end)
  end

  ## Linda Operations — default space

  def out(tuple) when is_tuple(tuple), do: out(:default, tuple)
  def in_(pattern, timeout), do: in_(:default, pattern, timeout)
  def rd(pattern, timeout), do: rd(:default, pattern, timeout)
  def in_nowait(pattern), do: in_nowait(:default, pattern)
  def rd_nowait(pattern), do: rd_nowait(:default, pattern)

  ## Linda Operations — named space

  @doc "Write a tuple into the space. Async."
  def out(space, tuple) when is_tuple(tuple) do
    case lookup(space) do
      {:ok, pid} -> Space.out(pid, tuple)
      {:error, _} = err -> err
    end
  end

  @doc "Blocking destructive read. Blocks until match or timeout (ms)."
  def in_(space, pattern, timeout) do
    case Pattern.compile(pattern) do
      {:error, _} = err -> err
      {:ok, _} ->
        case lookup(space) do
          {:ok, pid} -> Space.in_(pid, pattern, timeout)
          {:error, _} = err -> err
        end
    end
  end

  @doc "Blocking non-destructive read. Blocks until match or timeout (ms)."
  def rd(space, pattern, timeout) do
    case Pattern.compile(pattern) do
      {:error, _} = err -> err
      {:ok, _} ->
        case lookup(space) do
          {:ok, pid} -> Space.rd(pid, pattern, timeout)
          {:error, _} = err -> err
        end
    end
  end

  @doc "Non-blocking destructive read."
  def in_nowait(space, pattern) do
    case Pattern.compile(pattern) do
      {:error, _} = err -> err
      {:ok, _} ->
        case lookup(space) do
          {:ok, pid} -> Space.in_nowait(pid, pattern)
          {:error, _} = err -> err
        end
    end
  end

  @doc "Non-blocking non-destructive read. Bypasses GenServer — reads ETS directly."
  def rd_nowait(space, pattern) do
    case Pattern.compile(pattern) do
      {:error, _} = err -> err
      {:ok, spec} ->
        table = :"llmagent_ts_#{space}"
        match_pattern = spec |> hd() |> elem(0)
        try do
          case :ets.match_object(table, match_pattern) do
            [first | _] -> {:ok, first}
            [] -> {:error, :no_match}
          end
        rescue
          ArgumentError -> {:error, :space_not_found}
        end
    end
  end

  ## Private

  defp lookup(name) do
    case Registry.lookup(LLMAgent.TupleSpace.Registry, name) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :space_not_found}
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/tuple_space/tuple_space_test.exs`
Expected: all tests pass

- [ ] **Step 5: Run full test suite**

Run: `mix test`
Expected: all existing tests still pass, new tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/llmagent/tuple_space/tuple_space.ex lib/llmagent/application.ex test/tuple_space/tuple_space_test.exs
git commit -m "Add tuple space facade, wire supervision tree, start default space"
```

---

### Task 5: Documentation & README

**Files:**
- Modify: `README.md`
- Modify: `lib/llmagent/tuple_space/tuple_space.ex` (add doctests)
- Modify: `lib/llmagent/tuple_space/space.ex` (add @doc to start_link)

- [ ] **Step 1: Add doctests to facade functions**

Add doctests to the `@moduledoc` and key functions in `lib/llmagent/tuple_space/tuple_space.ex`. Use the `:default` space (available in test env).

- [ ] **Step 2: Add @doc to Space.start_link/1**

```elixir
  @doc """
  Start a space GenServer linked to the calling process.

  ## Options

    * `:name` (required) — atom used to register in `LLMAgent.TupleSpace.Registry`

  ## Examples

      iex> name = :"doctest_space_\#{System.unique_integer([:positive])}"
      iex> {:ok, pid} = LLMAgent.TupleSpace.Space.start_link(name: name)
      iex> is_pid(pid)
      true
      iex> GenServer.stop(pid)
      :ok
  """
```

- [ ] **Step 3: Update README.md**

Add a "Tuple Space" subsection after the "MCP Tools" section under "Tools". Add entries to the Key Modules table. Update test counts.

The README section should cover:
- What it is (Linda-style tuple space for agent coordination)
- Basic usage (out, in_, rd with examples)
- Named spaces
- Blocking vs non-blocking
- Pattern matching with `:_`

Also update the supervision tree diagram to include TupleSpace.Registry and TupleSpace.Supervisor.

- [ ] **Step 4: Run doctests**

Run: `mix test test/doctest_test.exs`
Expected: all doctests pass

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/tuple_space/tuple_space.ex lib/llmagent/tuple_space/space.ex README.md
git commit -m "Add tuple space docs, doctests, and README documentation"
```

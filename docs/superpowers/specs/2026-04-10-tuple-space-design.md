# Tuple Space — Design Spec

**Date:** 2026-04-10
**Status:** Approved
**Scope:** Linda-style tuple space for multi-agent coordination in LLMAgent

## Goal

Provide a shared coordination primitive for LLMAgent agents using Linda/JavaSpaces semantics. Agents write, read, and take tuples from named spaces using pattern matching. This is the BEAM differentiator — ETS-backed concurrent reads, GenServer-serialized mutations, and deferred replies for blocking operations.

## Scope

**In scope:**
- Full Linda semantics: `out` (write), `in_` (destructive read), `rd` (non-destructive read)
- Blocking variants with timeout (deferred GenServer reply)
- Non-blocking variants: `rd_nowait` (direct ETS bypass), `in_nowait` (through GenServer)
- Elixir-friendly pattern matching with `:_` wildcards, compiled to ETS match specs
- Named spaces under a DynamicSupervisor with Registry lookup
- A `:default` space started on application boot
- Mutation event emission (out, in_, lifecycle) via existing Events system
- Waiter process monitoring and cleanup

**Not in scope:**
- Durable/persistent tuple spaces (ephemeral coordination state only)
- Tool exposure for LLM access (future)
- Partitioned/sharded spaces (future, if contention becomes real)
- Integration with the Memory behaviour (separate concerns)
- NATS bridging (future)

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Semantics | Full Linda: out, in_, rd | Primitives are small and interdependent; subsetting is artificial |
| Storage | ETS duplicate_bag, public, named_table | Concurrent reads without GenServer serialization; duplicate_bag allows identical tuples |
| Architecture | Single GenServer per space | Agent coordination is low-frequency; simplicity over throughput |
| Blocking | Deferred GenServer.call reply + waiter list | Idiomatic GenServer pattern; clean synchronous API for callers |
| Non-blocking | rd_nowait bypasses GenServer, in_nowait through GenServer | rd is read-only so safe to go direct; in_ needs atomic remove |
| Patterns | Elixir tuples with `:_` wildcards → ETS match specs | Clean caller API with ETS-native matching speed |
| Supervision | DynamicSupervisor + Registry per space | Same pattern as AgentSupervisor and MCP ConnectionSupervisor |
| Events | Mutations only (out, in_, lifecycle) | Reads are high-frequency noise; mutations are observable state changes |
| Waiter priority | in_ before rd on new tuple | Classic Linda — destructive takes win over non-destructive reads |
| Durability | None | Ephemeral coordination state; durability is a separate backend concern |

## Architecture

### Module Structure

```
lib/llmagent/tuple_space/
  tuple_space.ex       # Public facade — out/in_/rd/rd_nowait/in_nowait + space management
  space.ex             # GenServer per named space — owns ETS, manages waiters
  pattern.ex           # Compiles Elixir-friendly patterns to ETS match specs

test/tuple_space/
  space_test.exs       # Unit tests for Space GenServer
  pattern_test.exs     # Pattern compilation tests
  tuple_space_test.exs # Facade + integration tests
```

### Supervision Tree (additions)

```
LLMAgent.Supervisor (existing, one_for_one)
├── ... existing children ...
├── Registry (LLMAgent.TupleSpace.Registry, keys: :unique)
├── DynamicSupervisor (LLMAgent.TupleSpace.Supervisor)
│   ├── LLMAgent.TupleSpace.Space (:default)   ← started by Application
│   ├── LLMAgent.TupleSpace.Space (:tasks)     ← started at runtime
│   └── ...
```

## Pattern Matching

### Pattern Module

`LLMAgent.TupleSpace.Pattern` compiles Elixir-friendly tuple patterns into ETS match specs.

**Input format:** Tuples with `:_` as wildcard.

```elixir
{:task, :pending, :_}          # match any pending task
{:result, :_, :_}              # match any result tuple
{:task, :pending, "build"}     # exact match
```

**Rules:**
- Input must be a tuple. Non-tuples return `{:error, :invalid_pattern}`.
- `:_` matches any value in that position.
- All other values are literal matches.

**API:**

```elixir
LLMAgent.TupleSpace.Pattern.compile({:task, :pending, :_})
# => {:ok, [{{:task, :pending, :_}, [], [:"$_"]}]}

LLMAgent.TupleSpace.Pattern.compile("not a tuple")
# => {:error, :invalid_pattern}

LLMAgent.TupleSpace.Pattern.match?({:task, :pending, :_}, {:task, :pending, "build"})
# => true

LLMAgent.TupleSpace.Pattern.match?({:task, :done, :_}, {:task, :pending, "build"})
# => false
```

`compile/1` output is passed directly to `:ets.match_object/2`.

`match?/2` is used by the GenServer to check waiters against newly written tuples without going back to ETS. It works by comparing element-by-element: `:_` in the pattern matches anything, other values must be equal.

## Space GenServer

### State

```elixir
%{
  name: :default,
  table: :ets.tid(),
  waiters: [waiter()]
}
```

A waiter:

```elixir
%{
  from: GenServer.from(),      # for deferred reply
  pattern: tuple(),            # original Elixir pattern
  operation: :in_ | :rd,       # in_ removes on match, rd doesn't
  timer: reference(),          # Process.send_after ref for timeout
  monitor: reference()         # Process.monitor ref for caller
}
```

### ETS Table

- Type: `:duplicate_bag` — allows identical tuples to coexist
- Access: `:public` — any process can read (for `rd_nowait`)
- Naming: `:named_table` — table name derived from space name as `:"llmagent_ts_#{name}"` (e.g., `:llmagent_ts_default`)

### Lifecycle

**init/1:**
- Create ETS table: `[:duplicate_bag, :public, :named_table]`
- Register via `{:via, Registry, {LLMAgent.TupleSpace.Registry, name}}`
- Emit `tuple_space.created` event
- State: `%{name: name, table: table, waiters: []}`

**handle_cast({:out, tuple}):**
1. Insert tuple into ETS via `:ets.insert/2`
2. Scan waiters for matches using `Pattern.match?/2`
3. Waiter dispatch priority:
   - First matching `:in_` waiter (FIFO) gets the tuple. Remove tuple from ETS, reply `{:ok, tuple}`, cancel timer, demonitor.
   - If no `:in_` waiter matches, all matching `:rd` waiters get `{:ok, tuple}` reply. Tuple stays in ETS. Cancel timers, demonitor each.
   - If both match, `:in_` wins — tuple is removed, `:rd` waiters don't see it.
4. Remove satisfied waiters from the list.
5. Emit `tuple_space.out` event with space name, tuple, and woken waiter count.

**handle_call({:in_, pattern, timeout}, from):**
1. Compile pattern via `Pattern.compile/1`
2. Try `:ets.match_object(table, compiled)` — if match found:
   - Delete one matching tuple from ETS via `:ets.delete_object/2`
   - Reply `{:ok, tuple}` immediately
   - Emit `tuple_space.in` event
3. If no match:
   - If timeout is 0, reply `{:error, :timeout}` immediately
   - Otherwise, monitor caller process, start timer via `Process.send_after(self(), {:waiter_timeout, ref}, timeout)`, add waiter to list, return `{:noreply, state}` (deferred reply)

**handle_call({:rd, pattern, timeout}, from):**
- Same as `in_` but does not delete the tuple on match. Waiter operation is `:rd`.

**handle_call({:in_nowait, pattern}, _from):**
1. Compile pattern, try match_object
2. If match: delete one, reply `{:ok, tuple}`, emit event
3. If no match: reply `{:error, :no_match}`

**handle_info({:waiter_timeout, ref}):**
- Find waiter by timer ref
- Reply `{:error, :timeout}` to the waiter's `from`
- Demonitor the caller
- Remove from waiters list

**handle_info({:DOWN, monitor_ref, :process, _pid, _reason}):**
- Find waiter by monitor ref
- Cancel timer
- Remove from waiters list (no reply needed — caller is dead)

**terminate/1:**
- ETS table is automatically cleaned up (owned by this process)
- Emit `tuple_space.destroyed` event

## Public API (Facade)

`LLMAgent.TupleSpace` is a stateless facade module. It looks up Space pids via Registry and routes operations. For `rd_nowait`, it bypasses the GenServer entirely.

### Space Management

```elixir
LLMAgent.TupleSpace.start_space(:tasks)
# => {:ok, pid}

LLMAgent.TupleSpace.stop_space(:tasks)
# => :ok

LLMAgent.TupleSpace.list_spaces()
# => [:default, :tasks]
```

### Linda Operations

All operations accept an optional space name as the first argument. When omitted, they use `:default`.

```elixir
# Write — async, returns :ok immediately
LLMAgent.TupleSpace.out({:task, :pending, "build_report"})
LLMAgent.TupleSpace.out(:tasks, {:task, :pending, "build_report"})
# => :ok

# Blocking destructive read
LLMAgent.TupleSpace.in_({:task, :pending, :_}, 5_000)
LLMAgent.TupleSpace.in_(:tasks, {:task, :pending, :_}, 5_000)
# => {:ok, {:task, :pending, "build_report"}}
# => {:error, :timeout}

# Blocking non-destructive read
LLMAgent.TupleSpace.rd({:task, :pending, :_}, 5_000)
# => {:ok, {:task, :pending, "build_report"}}
# => {:error, :timeout}

# Non-blocking variants
LLMAgent.TupleSpace.in_nowait({:task, :pending, :_})
# => {:ok, {:task, :pending, "build_report"}}
# => {:error, :no_match}

LLMAgent.TupleSpace.rd_nowait({:task, :pending, :_})
# => {:ok, {:task, :pending, "build_report"}}
# => {:error, :no_match}
```

### Routing

- `out/1,2` — GenServer.cast to the Space (async, fire-and-forget)
- `in_/2,3` and `rd/2,3` — GenServer.call with `:infinity` timeout (the Space manages the real timeout via deferred reply)
- `in_nowait/1,2` — GenServer.call to the Space
- `rd_nowait/1,2` — bypasses GenServer entirely. Compiles pattern, reads the named ETS table directly via `:ets.match_object/2`. Returns the first match if any, or `{:error, :no_match}`. Rescues `ArgumentError` if table doesn't exist and returns `{:error, :space_not_found}`.

## Error Handling

- **Space not found:** All facade functions return `{:error, :space_not_found}` if the named space doesn't exist in the Registry. `rd_nowait` rescues ETS `ArgumentError` for the same case.
- **Invalid patterns:** `Pattern.compile/1` returns `{:error, :invalid_pattern}` for non-tuple input. Facade propagates without calling the GenServer.
- **Space crashes:** DynamicSupervisor restarts the Space. ETS table is lost (owned by process). Callers blocked in `in_`/`rd` receive `{:EXIT, ...}` from GenServer.call. This is acceptable — tuple spaces are ephemeral coordination state.
- **Duplicate space names:** `start_space/1` returns `{:error, {:already_started, pid}}`.
- **Timeout of 0:** Equivalent to nowait — no waiter registered, returns `{:error, :timeout}` immediately.
- **Waiter process dies:** GenServer monitors waiter caller processes. On `{:DOWN, ...}`, removes the waiter entry and cancels its timer. No reply sent (caller is dead).

## Event Emission

Mutations only, through the existing `LLMAgent.Events` system.

| Topic | Type | Data |
|-------|------|------|
| `tuple_space.out` | `:out` | `%{space: name, tuple: tuple, waiters_woken: count}` |
| `tuple_space.in` | `:in` | `%{space: name, tuple: tuple}` |
| `tuple_space.created` | `:lifecycle` | `%{space: name}` |
| `tuple_space.destroyed` | `:lifecycle` | `%{space: name}` |

## Dependencies

No new dependencies. ETS is built into OTP. Events, Registry, DynamicSupervisor, and Comn.Errors.ErrorStruct are already available.

## Testing Strategy

- **Pattern** — unit tests for compile/1 (valid tuples, wildcards, invalid input) and match?/2 (positive matches, negative matches, all-wildcard, exact match).
- **Space** — unit tests for GenServer lifecycle: out + immediate rd, out + immediate in_, blocking rd with delayed out (use Task to write after delay), blocking in_ with timeout, waiter cleanup on caller death, waiter priority (in_ beats rd), duplicate tuples, ETS table cleanup on terminate.
- **Facade** — integration tests for named spaces: start/stop/list, default space operations, rd_nowait bypassing GenServer, error cases (space not found, invalid pattern).

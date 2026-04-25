# DurableLog + Event-Sourced Session Management

## Context

History and events are currently two separate copies of the same data. The agent maintains an in-memory message list (persisted to ETS via Memory), and separately emits events through EventBus/EventLog. This is redundant and fragile — the event stream is the authoritative record of everything the system does, but it lacks the data needed to reconstruct history, and it isn't durable.

This work makes events the single source of truth. A DurableLog GenServer subscribes to EventBus and appends every event to DETS. History is derived from the event stream, not stored separately. Sessions are time-bounded views over the log.

## Problem: Current Events Can't Reconstruct History

The existing events are missing content:

| Event | Topic | What's in data | What's missing |
|---|---|---|---|
| `:prompt` | `agent.prompt` | `content`, `role` | Nothing — has what we need |
| `:llm_response` | `agent.llm_response` | `content_length`, `is_tool_call` | **Actual response content** |
| `:tool_dispatch` | `agent.tool_dispatch` | `tool`, `action` | Fine — metadata only |
| `:invocation` | `tool.<name>` | `action`, `args`, `result` status, `duration_ms` | **Formatted result string** |
| `:error` | `agent.error` | `reason`, `source` | Fine |

Without the LLM response content and tool result content, we can't rebuild the message list.

## Design Decision: Message Events

Rather than stuffing content into existing events (which changes their purpose), emit a new `agent.message` event from `append_message/3`. Every history entry becomes an event:

```
append_message(state, "user", "hello")
  → appends to in-memory history
  → emits {:message, "agent.message", %{agent_id: name, role: "user", content: "hello"}}
```

History reconstruction = filter `agent.message` events for a given agent_id, ordered by timestamp. The system prompt is emitted as a message event during init.

This is clean because:
- Existing events keep their current shape (no breaking change to subscribers)
- Message events are a complete, ordered record of conversation state
- One event type to query, not a fold over multiple event types with different shapes
- `agent_id` on every message event enables multi-agent scoping

## Implementation Order

1. **Enrich `append_message` + init** — emit `agent.message` events with `agent_id`
2. **DurableLog GenServer** — DETS-backed subscriber, query API
3. **Session module** — history reconstruction from DurableLog, session boundaries
4. **Agent refactor** — init reconstructs from DurableLog, remove Memory `:history` writes
5. **Tests**

## Step 1: Emit Message Events

### `lib/LLMAgent.ex` — changes

**`append_message/3`** — add event emission after appending:

```elixir
defp append_message(state, role, content) do
  updated = update_in(state.history, &(&1 ++ [%{role: role, content: content}]))
  state.memory.store(state.name, :history, updated.history)

  Events.emit(:message, "agent.message", %{
    agent_id: state.name,
    role: role,
    content: content
  }, __MODULE__)

  updated
end
```

**`init/1`** — emit system prompt as message event after setting up history:

```elixir
# After history is established (whether restored or fresh):
Events.emit(:message, "agent.message", %{
  agent_id: name,
  role: "system",
  content: hd(history).content
}, __MODULE__)
```

Only emit the system prompt on fresh init (not when restoring from DurableLog — that would duplicate).

## Step 2: DurableLog GenServer

### `lib/llmagent/durable_log.ex` (new)

A GenServer that:
- On init, opens a DETS file
- On `record/1` (called from Events.emit), appends to DETS
- Provides query API for retrieval

**DETS structure:** `:duplicate_bag` keyed by `agent_id` (extracted from event data) or `:system` for events without agent_id. Each record is `{agent_id, event_struct}`. Retrieval by agent_id returns all events, sorted by timestamp.

**Integration:** `Events.emit/4` calls `DurableLog.record/1` directly (like it calls `EventLog.record/1`). DurableLog is a peer of EventLog, not an EventBus subscriber.

```elixir
defmodule LLMAgent.DurableLog do
  use GenServer

  ## Public API

  def start_link(opts)
  def record(event)              # cast — async append
  def messages_for(agent_id)     # call — returns [%{role, content}]
  def events_for(agent_id)       # call — returns [EventStruct]
  def events_for(agent_id, since: iso_timestamp)
  def clear(agent_id)            # call — remove one agent's events
  def clear()                    # call — remove all events

  ## GenServer

  # init: open DETS file at data/llmagent_events.dets, type: :duplicate_bag
  # handle_cast {:record, event}: extract agent_id from event.data, insert {agent_id, event}
  # handle_call {:messages_for, id}: lookup, filter topic=="agent.message", map to %{role, content}
  # handle_call {:events_for, id}: lookup, sort by timestamp
  # handle_call {:events_for, id, since: ts}: lookup, filter, sort
  # handle_call {:clear, id}: match_delete
  # handle_call :clear_all: delete_all_objects
  # terminate: dets.close
end
```

### `lib/llmagent/events.ex` — change

Add `DurableLog.record(event)` alongside `EventLog.record(event)`.

### `lib/llmagent/application.ex` — change

Add DurableLog to supervision tree (after EventLog).

## Step 3: Agent Refactor — History from DurableLog

### `lib/LLMAgent.ex` — init changes

On startup, try DurableLog first, then Memory.ETS, then fresh:

```elixir
defp restore_history(name, role, memory) do
  # Try DurableLog first (survives node restarts)
  case LLMAgent.DurableLog.messages_for(name) do
    messages when is_list(messages) and messages != [] ->
      {messages, true}
    _ ->
      # Fall back to Memory.ETS (survives process restarts within same node)
      case memory.fetch(name, :history) do
        {:ok, saved} when saved != [] -> {saved, true}
        _ -> {[%{role: "system", content: RolePrompt.get(role)}], false}
      end
  end
end
```

Only emit system prompt message event on fresh start (not restored).
Keep Memory.ETS dual-write in append_message as fast read cache.

## Step 4: Tests

### New: `test/durable_log_test.exs`

- `record/1` persists event to DETS
- `events_for/1` returns all events for agent_id, sorted by timestamp
- `events_for/2` with `since:` filters by timestamp
- `messages_for/1` returns only `agent.message` events as `%{role, content}` maps
- `clear/1` removes events for one agent
- `clear/0` removes all events
- Events without `agent_id` in data are keyed as `:system`
- Two agents get isolated event streams

### Updates to existing tests

- Add `LLMAgent.DurableLog.clear()` to setup blocks
- Update lifecycle persistence test to verify DurableLog reconstruction
- Add message event emission tests

## Files Summary

| File | Action |
|---|---|
| `lib/llmagent/durable_log.ex` | **New** — DETS-backed event log GenServer |
| `lib/llmagent/events.ex` | **Modify** — add `DurableLog.record(event)` call |
| `lib/llmagent/application.ex` | **Modify** — add DurableLog to supervision tree |
| `lib/LLMAgent.ex` | **Modify** — emit message events from `append_message`, restore from DurableLog in init |
| `test/durable_log_test.exs` | **New** — DurableLog tests |
| `test/llmagent_test.exs` | **Modify** — add DurableLog.clear to setup, add message event tests |
| `test/agent_lifecycle_test.exs` | **Modify** — add DurableLog.clear to setup, update persistence test |

## What This Does NOT Do

- No SQLite backend — DETS for now, SQLite is a future swap
- No session boundaries/naming — sessions are implicit (time ranges over the log)
- No EventLog removal — EventLog stays as the fast in-memory queryable log
- No Memory behaviour changes — Memory.ETS still works for scratch state
- No changes to existing event shapes — `agent.message` is additive

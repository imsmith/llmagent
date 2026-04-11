# Agent Orchestration: TupleSpace Tool + Agent Tool

**Date:** 2026-04-11
**Status:** Draft

## Overview

Two new tools that let a root agent create, command, and coordinate child agents. Lifecycle management lives in an Agent tool. All communication flows through the existing tuple space via a new TupleSpace tool. Composable primitives, not a monolith.

## Design Constraints

- Only root agents (started by a human) can spawn children. One level deep.
- Children that lose their parent finish their work and write results to the tuple space.
- Child tool access is whitelist-only, specified at spawn time.
- Three communication modes chosen per-spawn: sync (blocking), async (tuple space), or streaming (tuple space with intermediate writes).

## TupleSpace Tool

New module: `LLMAgent.Tools.TupleSpace`

Implements the `LLMAgent.Tool` behaviour. Thin adapter over the existing `LLMAgent.TupleSpace` facade.

### Actions

| Action | Args | Behavior |
|--------|------|----------|
| `write` | `space`, `tuple` | `out/2` — write tuple to named space |
| `read` | `space`, `pattern`, `timeout` | `rd/3` — non-destructive blocking read |
| `take` | `space`, `pattern`, `timeout` | `in_/3` — destructive blocking read |
| `read_nowait` | `space`, `pattern` | `rd_nowait/2` — non-blocking peek |
| `take_nowait` | `space`, `pattern` | `in_nowait/2` — non-blocking consume |
| `list_spaces` | — | enumerate active spaces |
| `create_space` | `name` | start a named space |
| `destroy_space` | `name` | stop a named space |

### Data Encoding

Tuples and patterns arrive as JSON arrays from the LLM. Converted to Elixir tuples on ingress. The string `"_"` in a pattern maps to the atom `:_` (wildcard). Results converted back to JSON arrays on egress.

## Agent Tool

New module: `LLMAgent.Tools.Agent`

Implements the `LLMAgent.Tool` behaviour. Lifecycle management only — no communication.

### Actions

| Action | Args | Behavior |
|--------|------|----------|
| `spawn` | `name`, `prompt`, `tools`, `mode`, `model` (opt), `timeout` (opt) | Start a child agent |
| `kill` | `name` | Stop a child by name |
| `list` | — | Running children with state |
| `status` | `name` | Check if a specific child is running |

### Spawn Modes

**Sync** (`mode: "sync"`):
1. Start child under `AgentSupervisor`
2. Call `LLMAgent.prompt(child_name, prompt)`, block on result
3. Stop child after completion
4. Return final assistant message as tool result
5. Default timeout: 120s. Configurable via `timeout` arg.

**Async** (`mode: "async"`):
1. Start child under `AgentSupervisor` with `parent` field set
2. Fire-and-forget `LLMAgent.prompt(child_name, prompt)`
3. Return immediately: `{:ok, %{output: "agent #{name} started"}}`
4. Child runs independently
5. On conversation completion, child writes `{:agent_result, name, result}` to `:default` tuple space and self-terminates

### Spawn Depth Enforcement

`perform("spawn", ...)` checks the calling agent's state for `parent != nil`. If the caller is already a child, returns `{:error, "child agents cannot spawn further agents"}`.

## Agent State Changes

Two new fields in the `LLMAgent` GenServer state:

```elixir
%{
  # ... existing fields ...
  parent: atom | nil,         # name of spawning agent, nil for root
  allowed_tools: [atom] | :all  # tool whitelist, :all for root
}
```

### Tool Dispatch Modification

`timed_dispatch/3` checks `allowed_tools` before invoking any tool. If the tool atom is not in the whitelist, returns `{:error, "tool :bash not permitted"}` without dispatching. No event emitted — normal control flow for the child's LLM to adapt.

### Conversation Completion for Child Agents

When a child agent's LLM returns a non-tool-call response (conversation complete) and `parent != nil`:
1. Write `{:agent_result, name, final_response}` to `:default` tuple space
2. Call `AgentSupervisor.stop_agent(self_name)` for clean exit

## Communication Patterns

Not encoded in the framework. Documented as conventions for orchestrator system prompts.

### Task Assignment (async)

```
Parent: out(:default, {:task, child_name, "analyze logs in /var/log"})
Child:  in_(:default, {:task, my_name, :_})
Child:  out(:default, {:agent_result, my_name, result})
Parent: in_(:default, {:agent_result, child_name, :_})
```

### Fan-out / Fan-in

```
Parent spawns N async children with different prompts.
Each child writes {:agent_result, name, result} on completion.
Parent does N blocking in_ calls to collect all results.
```

### Streaming Intermediate Results

```
Child:  out(:default, {:progress, my_name, step_1_result})
Child:  out(:default, {:progress, my_name, step_2_result})
Child:  out(:default, {:agent_result, my_name, final_result})
Parent: rd(:default, {:progress, child_name, :_})
Parent: in_(:default, {:agent_result, child_name, :_})
```

## Error Handling

### Child Crashes

Children are one-shot tasks — `AgentSupervisor` does not restart them. On crash, the child's `terminate/2` callback writes `{:agent_error, name, reason}` to the tuple space so the parent can distinguish "still running" from "dead."

### Tool Whitelist Violations

Returns `{:error, "tool :bash not permitted"}` to the child's LLM. The LLM adjusts and uses available tools.

### Spawn Depth Violations

Returns `{:error, "child agents cannot spawn further agents"}` as a tool result.

### Sync Timeout

If the child doesn't complete within the timeout, parent kills it and gets `{:error, "agent :worker timed out after 120000ms"}`. Child's `terminate/2` still fires, so a partial result or error tuple may land in the tuple space.

### LLM Budget

No explicit token or turn limits. Sync timeout catches runaway children. Async children can be killed by the parent. Max-turns is a future iteration if needed.

## Orphan Behavior

Child monitors its parent process. If the parent dies:
1. Child logs an `agent.orphaned` event
2. Child continues running to completion
3. Result writes to tuple space as normal
4. Child self-terminates on completion

Results have a place to land even if nobody's listening yet.

## Files Changed

### New

- `lib/tools/tuple_space.ex` — TupleSpace tool module
- `lib/tools/agent.ex` — Agent tool module

### Modified

- `lib/llm_agent.ex` — add `parent` and `allowed_tools` to state; modify `timed_dispatch` for whitelist check; modify conversation-complete path for child self-termination and tuple space write
- `lib/tools.ex` — register `:tuple_space` and `:agent` in `init_registry/0`

### Unchanged

- Tuple space modules (used through public API)
- EventBus, EventLog, DurableLog (children emit events naturally)
- AgentSupervisor (already supports dynamic spawn/stop)
- Memory, LLMClient

## Testing

- Unit: TupleSpace tool `perform/2` for each action
- Unit: Agent tool `perform/2` for each action
- Integration: root agent spawns sync child, gets result back
- Integration: root agent spawns async child, collects from tuple space
- Integration: child attempts spawn, gets denied
- Integration: parent dies, orphan completes and writes result
- Integration: child crashes, error tuple lands in tuple space
- Integration: child attempts disallowed tool, gets rejected

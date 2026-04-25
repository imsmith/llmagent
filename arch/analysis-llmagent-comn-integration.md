# LLMAgent ↔ Comn: Duplications, Replacements, and Gap-Fillers

**Date**: 2026-02-15
**Context**: Audit of how LLMAgent uses (and should use) Comn v0.4.0.

---

## 1. Direct Duplications — Delete These From LLMAgent

### EventBus (identical code)

LLMAgent's `lib/event_bus.ex` is an 11-line Registry-based pub/sub wrapper. Comn's `Comn.EventBus` is the same thing — same `subscribe/1`, same `broadcast/2`, same `Registry.dispatch` pattern. The only difference is the module name and Registry name.

**Action**: Delete `lib/event_bus.ex`. Alias `Comn.EventBus`. Change the supervision tree to register `Comn.EventBus` instead of `LLMAgent.EventBus`. Update all call sites (LLMAgent.ex, require_binary.ex).

### EventLog (identical code)

LLMAgent's `lib/event_log.ex` is a 72-line Agent-based append-only log. Comn's `Comn.EventLog` has the same API: `record/1`, `all/0`, `for_topic/1`, `for_type/1`, `since/1`, `clear/0`. LLMAgent's version already calls `Comn.Event.to_event/1` internally — it's a copy that delegates to Comn for the hard part.

**Action**: Delete `lib/event_log.ex`. Alias `Comn.EventLog`. Update supervision tree and all call sites.

**Net savings**: ~83 lines removed, two fewer modules to maintain, and the event system is unified across the Comn ecosystem.

---

## 2. Underused Comn Features — Start Using These

### Comn.Errors.categorize/1 and Comn.Errors.wrap/1

LLMAgent manually constructs every `ErrorStruct.new/3,4` call with hand-typed reason strings like `"command_failed"`, `"missing_args"`, `"execution_error"`. Comn provides:

- `Errors.categorize/1` — auto-classifies reasons into `:validation`, `:network`, `:auth`, `:persistence`, `:internal`, `:unknown`
- `Errors.wrap/1` — converts arbitrary terms (strings, atoms, maps, tuples) into ErrorStruct via the protocol

LLMAgent has ~18 error construction sites across 11 tool modules. None use categorization. The `format_tool_result/1` function in LLMAgent.ex already calls `Comn.Error.to_error/1`, but the tools upstream don't use the richer error creation API.

**Action**: Replace raw `ErrorStruct.new` calls with `Errors.new(:category, message, field, suggestion)` where the category adds value for downstream routing/filtering.

### Comn.Contexts — Request Context Propagation

This is the biggest unused feature. Comn provides:

- `Comn.Contexts.ContextStruct` with `request_id`, `trace_id`, `correlation_id`, `user_id`, `actor`, `env`, `zone`, `parent_event_id`, `metadata`
- `Comn.Contexts.new/1` — create and attach to current process
- `Comn.Contexts.fetch/1` — read from current process
- `Comn.Contexts.with_context/2` — scoped context for a block

LLMAgent has **zero** request context. Each `prompt/2` call has no ID, no trace, no correlation. Events get emitted but can't be tied back to the prompt that caused them. Tool calls can't be correlated across an agent loop iteration.

**Action**: On each `handle_call({:prompt, content}, ...)`, create a context with a unique `request_id`. Propagate it into the Task that calls the LLM. Include `request_id` in all emitted events. This gives you distributed tracing for free when you eventually wire up NATS.

### Comn.Repo.Table.ETS — Agent State Caching

Comn has a full ETS backend with `create/2`, `get/2`, `set/2`, `delete/2`, `keys/1`, `count/1`. LLMAgent stores conversation history in GenServer state — it dies with the process. ETS survives process restarts under the same node.

**Action**: Use `Comn.Repo.Table.ETS` to persist conversation history keyed by agent name. On agent restart, reload from ETS. This isn't full persistence (dies with the node), but it's crash recovery without adding a database.

### Comn.Secrets.Local — API Key Management

LLMAgent reads `LLMAGENT_API_HOST` from env vars. If you ever need to store API keys for LLM providers, Comn provides ChaCha20-Poly1305 AEAD encryption with Ed25519 keys. The `Secrets.Local` module is production-ready.

**Action**: Not urgent for the sprint, but when you add multi-provider support, use `Comn.Secrets` instead of bare env vars.

---

## 3. Design Doc Gaps That Comn Already Fills

The design doc described several features that Comn provides but LLMAgent hasn't wired up:

| Design Doc Feature | Comn Module | Status |
|---|---|---|
| Memory behaviour (ETS/Mnesia/Nebulex) | `Comn.Repo.Table.ETS` | **Ready** — full implementation |
| Event observability with Telemetry | `Comn.EventBus` + `Comn.EventLog` | **Ready** — identical to what LLMAgent reimplemented |
| NATS client for distributed messaging | `Comn.Events.NATS` | **Ready** — GenServer wrapping Gnat, bridges to EventBus |
| Tuple space coordination | `Comn.Repo.Table.ETS` (partial) | ETS gives you a shared key-value store; not a full Linda space, but the storage primitive is there |
| Request context propagation | `Comn.Contexts` | **Ready** — process-scoped, supports trace_id/request_id |
| Graph-based agent coordination | `Comn.Repo.Graphs.Graph` | **Ready** — libgraph backend with traversal queries |
| File operations with lifecycle | `Comn.Repo.File.Local` | **Ready** — state machine (open→load→read/write→close) |
| Policy/rules for tool access control | `Comn.Contexts.PolicyStruct` + `RuleStruct` | **Defined** — structs exist, no evaluation engine |

### The NATS Bridge Is Already Built

The design doc's NATS integration for Prolog offload? Comn has `Comn.Events.NATS` — a GenServer that connects to NATS via Gnat, subscribes to topics, and bridges messages into the local EventBus. It's not a full Prolog integration, but the transport layer is done. LLMAgent could emit events that cross node boundaries today if NATS were running.

### The ETS Table Is the Memory Backend

The design doc wanted swappable memory backends (ETS, Mnesia, Nebulex). `Comn.Repo.Table.ETS` implements the `Comn.Repo` behaviour with `get/set/delete/observe`. You don't need Mnesia or Nebulex for the sprint — ETS gives you per-node persistence that survives agent process crashes.

---

## 4. Things LLMAgent Has That Comn Doesn't (Keep These)

| LLMAgent Module | Why It Stays |
|---|---|
| `Utils.Encoder` / `Utils.Decoder` | Base58/64/hex encoding for crypto tool. Comn doesn't provide encoding utils. |
| `Utils.Time` | ISO8601 timestamp helper. Comn uses timestamps but doesn't expose a utility for them. |
| `Utils.RequireBinary` | System binary checking. LLMAgent-specific concern. |
| `Tool` behaviour + `Tools` registry | Agent-specific tool dispatch. Not a Comn concern. |
| All 10 tool modules | Domain-specific implementations. |
| `RolePrompt` + prompt modules | Agent-specific prompt management. |
| The agent GenServer itself | Core application logic. |

---

## 5. Recommended Priority Order

**During the sprint (Days 11-15):**

1. **Replace EventBus/EventLog** with Comn's versions. Mechanical change, eliminates duplication, 30 minutes of work. Update supervision tree to start `Comn.EventBus` Registry and `Comn.EventLog` Agent.

2. **Add Comn.Contexts** to the agent loop. Create a context per prompt, propagate request_id into events. This makes your event log queryable per-conversation-turn.

3. **Use Comn.Repo.Table.ETS** for conversation history persistence. On agent init, check ETS for prior history. On each history update, write-through to ETS.

**Post-sprint:**

4. Wire up `Comn.Events.NATS` for distributed event propagation.
5. Use `Comn.Secrets.Local` for API key storage.
6. Explore `PolicyStruct`/`RuleStruct` for tool access control.
7. Use `Comn.Repo.Graphs.Graph` if you build multi-agent coordination (agent dependency graphs, tool call graphs).

---

## Summary

LLMAgent currently uses Comn as a struct library — `ErrorStruct` and `EventStruct` and nothing else. Meanwhile it reimplements Comn's EventBus and EventLog line-for-line. The fix is straightforward: delete the duplicates, start using Contexts for tracing, and use ETS for crash recovery. That gets you from "Comn is a struct dependency" to "Comn is the infrastructure layer" — which is what it was designed to be.

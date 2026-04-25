# LLMAgent: Design vs Implementation vs OpenClaw

**Date**: 2026-02-15
**Context**: Comparison of the original "Agento" design doc, the current LLMAgent implementation, and the OpenClaw project.

---

## Part 1: Design Doc vs Implementation — Where You Diverged

The design doc describes **"Agento"** — a full DSL-driven framework inspired by LangChain/CrewAI. The implementation is **LLMAgent** — a focused GenServer agent with tool dispatch and events. The gap is substantial but not accidental; you built the useful core and skipped the ceremony.

### What Got Built (and works)

| Design Concept | Implementation | Fidelity |
|---|---|---|
| OTP-first agents under supervisors | GenServer agent + Task.Supervisor + DynamicSupervisor | **High** — idiomatic OTP |
| Tool behaviour with `call/2` | Tool behaviour with `perform/2` (action, args) | **Modified** — richer interface |
| LLM client integration | Direct `Req.post` to OpenAI-compatible API | **Simplified** — no behaviour abstraction |
| Event observability | EventBus (Registry pub/sub) + EventLog (Agent-based) | **Partial** — events exist, no `:telemetry` hooks |
| Structured errors | Comn.Errors.ErrorStruct throughout | **Solid** |

### What Got Cut

| Design Concept | Status | Assessment |
|---|---|---|
| **DSL macros** (`defchain`, `deftool`, `defmemory`, `use Agento`) | Not implemented | Correct call. Macros add cognitive overhead before you have the semantics right. |
| **Chain/pipeline abstraction** | Not implemented | The agent loop *is* a chain — prompt → tool → result → loop. You skipped the abstraction layer. |
| **Memory behaviour** (Nebulex, Mnesia, ETS) | Not implemented | Conversation history lives in GenServer state. No persistence, no retrieval. |
| **Retriever behaviour** (vector stores) | Not implemented | No RAG pattern at all. |
| **Stateless functions** (Lambda-style) | Not implemented | Tools serve this role informally. |
| **Tuple space** (Linda/JavaSpaces) | Not implemented | The most architecturally interesting idea in the doc — completely absent. |
| **NATS client** + Prolog offload | Not implemented | Infrastructure integration deferred. |
| **Action Model / LAM** | Not implemented | The LLM *is* the action model — it picks tools via JSON. No separate decision layer. |
| **NimbleOptions config** | Not implemented | Config via `Application.get_env` and start_link opts. |
| **Mox-based testing** | Not implemented | Tests use `simulate_llm_response` helper instead. |

### The Real Divergence

The design doc imagines a **framework** — something other developers compose with macros and behaviours to build agents. LLMAgent is an **application** — a single agent that talks to an LLM and dispatches tools. That's the core fork.

The design doc has **five abstraction layers** (behaviours → DSL macros → pipelines → supervisors → config). LLMAgent has **two** (tool behaviour → agent GenServer). Everything else is direct function calls.

**This is defensible.** You have 86 passing tests and a working agent loop. The design doc has zero executable code. But it means scaling to multi-agent, persistent memory, or cross-service coordination requires rethinking, not just adding modules.

---

## Part 2: LLMAgent vs OpenClaw

OpenClaw is a 366K-line TypeScript project (Node.js) that serves as a personal AI assistant with multi-channel messaging integration. It uses an external agent runtime (`pi-agent-core` from the pi-mono project) and focuses on being a **control plane** for multiple messaging surfaces.

### Architecture Comparison

| Dimension | LLMAgent | OpenClaw |
|---|---|---|
| **Language** | Elixir/OTP | TypeScript/Node.js |
| **Lines of code** | ~2K | ~366K |
| **Agent runtime** | Custom GenServer | External (pi-mono) |
| **State** | In-memory (GenServer) | JSONL files + JSON store |
| **Concurrency** | BEAM processes, supervision trees | Single-threaded, lane-based queues |
| **Tool definition** | Elixir modules with `perform/2` | TypeBox schemas + TypeScript functions |
| **Tool dispatch** | Atom-based registry (`Tools.bash()`) | String name lookup in tool registry |
| **Session persistence** | None (memory only) | JSONL transcripts on disk |
| **Multi-channel** | None | 10+ (WhatsApp, Telegram, Discord, Slack, Signal...) |
| **Gateway** | None | WebSocket server (JSON-RPC protocol) |
| **Error recovery** | Supervisor restarts, structured errors | Auth rotation, model fallback chains, context compaction |
| **Sandboxing** | None | Docker container isolation |
| **Extension model** | Tool modules only | Plugins + Skills (markdown files) + Bootstrap files |
| **LLM providers** | Single (OpenAI-compatible) | Anthropic, OpenAI, Google, Bedrock, Copilot, local |

### What OpenClaw Does That LLMAgent Doesn't

1. **Multi-channel messaging gateway** — WebSocket server routing messages from WhatsApp/Telegram/Discord/etc. to agents and back. This is OpenClaw's core value prop.

2. **Session management** — Hierarchical session keys, daily resets, idle timeouts, per-peer/per-channel scoping. LLMAgent's history dies with the process.

3. **Tool policy system** — Multi-layer allowlist/denylist resolution (global → agent → provider → profile → group → sandbox). LLMAgent has no access control on tools.

4. **Skills as context injection** — Markdown files with YAML frontmatter that teach the agent *how* to use tools, loaded conditionally based on OS/binaries/env. Separate from tool definitions.

5. **Error classification and failover** — Auth profile rotation, model fallback chains, thinking-level downgrade, context compaction on overflow. LLMAgent logs errors and stays alive but doesn't adapt.

6. **Block streaming** — Chunked output delivery to messaging surfaces (paragraph/sentence boundaries). LLMAgent has no streaming.

7. **Node/device protocol** — Remote device pairing (macOS/iOS/Android nodes) for cross-device actions.

8. **Bootstrap files** — `AGENTS.md`, `SOUL.md`, `TOOLS.md`, `IDENTITY.md`, `USER.md` for workspace-based agent configuration. Clean pattern.

### What LLMAgent Has That OpenClaw Handles Differently

1. **True process isolation** — Each agent is a supervised BEAM process. OpenClaw serializes via lane queues on a single thread.

2. **EventBus + EventLog** — Structured event pub/sub with queryable in-memory log. OpenClaw emits events over WebSocket but doesn't have a queryable event store.

3. **Comn integration** — Shared error/event structs across a dependency ecosystem. OpenClaw's error handling is ad-hoc TypeScript.

4. **System administration tools** — DBus, Systemd, Udev, Proc, Net, Inotify. OpenClaw has `exec` (shell) and browser automation but no purpose-built Linux admin tools.

5. **Cryptographic tool** — Ed25519/ECDSA with proper key management. OpenClaw has no built-in crypto.

### What the Design Doc Has That OpenClaw Also Has (But LLMAgent Doesn't)

| Concept | Design Doc | OpenClaw | LLMAgent |
|---|---|---|---|
| Plugin/extension system | `deftool`, `defchain` macros | Plugins dir + Skills (markdown) | Nothing |
| Memory/persistence | Memory behaviour (ETS/Mnesia/Nebulex) | JSONL session transcripts | None |
| Multi-agent coordination | DynamicSupervisor for multiple agents | Agent routing + `sessions_*` tools | Single agent only |
| Configuration management | NimbleOptions | JSON5 config file + layered overrides | `Application.get_env` |

---

## Part 3: Honest Assessment

### LLMAgent's Strengths
- Clean, tested, working code
- Idiomatic Elixir/OTP
- Strong tool behaviour contract
- Good event system foundation
- Comn dependency gives structured errors/events for free
- Linux system admin focus is a genuine niche

### LLMAgent's Gaps (Relative to Both the Design and OpenClaw)
- **No persistence** — agent memory dies with the process
- **No multi-agent** — design doc imagined DynamicSupervisor for N agents; only one exists
- **No extension model** — can't add tools/behaviors without modifying source
- **No session management** — no concept of conversations, resets, or scoping
- **No streaming** — blocking request/response only
- **Single LLM provider** — hardcoded OpenAI-compatible API shape
- **No access control** — any tool call from the LLM executes unconditionally

### The Tuple Space Question

The most interesting idea in the design doc — the Linda/JavaSpaces tuple space — appears in neither LLMAgent nor OpenClaw. OpenClaw uses lane-based queues and session-scoped file state. LLMAgent uses GenServer state. Neither has a shared coordination primitive that enables the kind of loosely-coupled multi-agent communication the design doc envisions. If you're going to differentiate from OpenClaw architecturally, this is where BEAM's strengths actually matter — ETS-backed tuple spaces with process-level pattern matching would be genuinely hard to replicate in Node.js.

### The NATS/Prolog Question

Also unique to the design doc and absent from OpenClaw. Cross-runtime communication via message bus is an infrastructure-engineering approach to agent coordination. OpenClaw does everything in-process. If you want agents that span runtimes (Elixir agent coordinating with Prolog reasoner, or with other services), this is another genuine differentiator — but it's unbuilt.

---

## Summary

**Design → Implementation gap**: Large. You built the agent loop and tool dispatch core. Everything above that (DSL, chains, memory, tuple space, NATS, LAM) is unbuilt. The implementation is a **foundation**, not the framework the design describes.

**LLMAgent vs OpenClaw**: Different animals. OpenClaw is a mature personal assistant control plane for messaging surfaces. LLMAgent is a minimal agent loop for Linux system administration. They share the core pattern (LLM → tool call → result → loop) but diverge on everything else. OpenClaw has ~180x more code and years of iteration.

**Where to go**: The design doc's most differentiating ideas — tuple space, NATS integration, Prolog offload, OTP supervision of multiple agents — are the things OpenClaw *can't easily do* because of its single-threaded Node.js architecture. Those are where BEAM actually wins. But they're also the hardest to build and the furthest from shipping.

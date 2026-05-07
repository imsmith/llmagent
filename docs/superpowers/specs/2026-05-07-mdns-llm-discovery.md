# mDNS LLM Endpoint Discovery — Spec

**Date:** 2026-05-07
**Status:** Approved for implementation
**Substrate dependency:** Builds on `2026-05-03-tool-discovery-design.md` (substrate landed at `40dec29`).

## Problem

Local `llama.cpp` servers on the LAN advertise themselves via mDNS as `_llama._tcp` services with TXT records carrying model name, context window, slot count, and status. The agent currently has a single `LLMClient.OpenAI` pinned to one `api_host` via app config — adding more endpoints means hand-editing config, and endpoints come and go (laptops sleep, models swap). The discovery substrate is in place; it should consume these advertisements.

## Approach

A userspace shim translates mDNS browse output into `LLMAgent.ToolAd` records and ships them over a pipe to a BEAM-side reader. The reader is a thin GenServer that parses EDN, builds the `ToolAd` struct, and calls `LLMAgent.Tools.Discovery.{register,update,unregister}/1`. The shim owns mDNS protocol details and the `_llama._tcp` schema; the BEAM stays generic and could read from any source emitting the same EDN format.

A new `:generate` tool kind is introduced for stochastic, retryable-but-not-cacheable LLM completion. A new `:openai_chat` binding adapter implements `:generate` against an OpenAI-compatible HTTP endpoint by delegating to the existing `LLMAgent.LLMClient.OpenAI`.

## Why a port (pipe), not a unix socket

Erlang ports are the canonical mechanism for spawning and reading external processes. Lifecycle (crash, restart, supervision) is solved by the existing supervision tree. A port *is* a pipe — the user's "linux pipe" choice falls out naturally. Unix sockets buy multi-writer support and arbitrary-language clients; we want neither for v1. One supervised port per discovery source.

## Why `:generate` is a new kind

The six canonical kinds (`:query`, `:action`, `:stream`, `:compute`, `:coordinate`, `:spawn`) all carry load-bearing invariants the agent reasons against. `:compute` and `:query` are pure / deterministic / freely retryable; an LLM call is stochastic. `:action` carries side-effecting mutation semantics with idempotency keys, which doesn't match either. The kinds registry is open precisely so substrate-shaped extensions stay honest about their contracts. `:generate` declares: stochastic, retryable, **not** cacheable, returns a value plus provenance (model, tokens, latency).

## Components

| Component | Path | Responsibility |
|---|---|---|
| Tcl shim | `priv/discovery/avahi-llama.tcl` | Wraps `avahi-browse`, maintains name→id table, emits EDN events |
| Port adapter | `lib/llmagent/discovery/port_adapter.ex` | Supervises shim, parses EDN, calls Discovery |
| EDN codec | `lib/llmagent/discovery/wire.ex` | Encode/decode the ad wire schema (using `eden`) |
| Generate kind | `lib/llmagent/tool/kinds/generate.ex` | Behaviour module for stochastic completion |
| OpenAI-chat adapter | `lib/llmagent/tool/adapter/openai_chat.ex` | Binding adapter implementing `:generate` via `LLMClient.OpenAI` |
| App wiring | `lib/llmagent/application.ex` | DynamicSupervisor + child specs from config |

## Wire format

EDN, one record per line on the shim's stdout. Two event types:

```edn
{:event :register
 :ad {:id "mdns:_llama._tcp:skynet001-llama-server:8080"
      :coordinate "compute.llm.chat"
      :kinds [:generate]
      :binding [:openai_chat {:api_host "http://10.10.1.226:8080" :model "gemma-4-26B-A4B-it-Q4_K_M.gguf"}]
      :operational {:actions {"chat" {:concurrency 4}} :model_id "gemma-4-26B-A4B-it-Q4_K_M.gguf"}
      :constraint  {:idempotency {} :blast_radius {}}
      :affordance  {:declared [{:intent :long_context :n_ctx 262144}] :learned [] :open true}
      :fidelity    :authoritative
      :provenance  {:source "mdns/_llama._tcp" :produced_at "2026-05-07T15:00:00Z" :based_on [] :signature nil}
      :lease       [:expires_at "2026-05-07T15:01:00Z"]}}

{:event :expire
 :id "mdns:_llama._tcp:skynet001-llama-server:8080"}
```

The shim is responsible for stable IDs (host + service-instance-name + port). On mDNS goodbye (`-` event from `avahi-browse`), it emits `:expire`. On rebind / shim restart, it re-emits `:register` for everything currently visible — the adapter handles re-registration by trying `register/1` first and falling back to `update/1` on `:duplicate_id`.

## Coordinate scheme

`compute.llm.chat` for chat-completion endpoints. The `compute.` prefix is namespace-only here (LLM endpoints are not the `:compute` kind); the prefix groups "computation-shaped affordances" in the coordinate tree. Future siblings: `compute.llm.embed`, `compute.llm.complete`. The kind is carried independently in `:kinds` (see ad above).

## TXT → ad mapping (Tcl shim's job)

| TXT key | Ad field |
|---|---|
| `model=...` | `operational.model_id` and embedded in `:binding` payload |
| `n_ctx=N` | `affordance.declared` entry `{intent: :long_context, n_ctx: N}` |
| `slots=N` | `operational.actions["chat"].concurrency` |
| `status=ok` | gates registration; non-`ok` → emit `:expire` if previously registered |
| `api=openai-compatible` | required; mismatched values cause the shim to skip the record |
| `server=llama.cpp` | `provenance.source` becomes `mdns/_llama._tcp/llama.cpp` |
| `hostname=...` | reserved for future capability inference |

## Lease policy

Shim sets `lease: [:expires_at, now+60s]` on every register. While the service is visible, the shim re-emits `:register` every 30s with a refreshed expiry (Discovery's `update` accepts duplicates). When mDNS goodbye arrives, shim emits `:expire`; if the shim itself dies, leases expire naturally inside 60s and Discovery's sweep removes them.

## Configuration

Per source, in `config/config.exs`:

```elixir
config :LLMAgent, :discovery_adapters, [
  %{
    name: :avahi_llama,
    command: "tclsh",
    args: ["priv/discovery/avahi-llama.tcl"],
    env: []
  }
]
```

The application starts a `DynamicSupervisor` (`LLMAgent.Discovery.AdapterSupervisor`) and launches one `PortAdapter` child per configured entry.

## Failure modes

- **avahi not installed / not running** — shim exits non-zero, port closes, supervisor restarts shim with backoff. Logged warning. Discovery sweep evicts stale ads after lease expiry.
- **Malformed EDN line** — adapter logs the raw line and skips. Does not crash.
- **TXT record missing required field** — shim skips that record (does not emit any event).
- **Duplicate id on register** — adapter falls back to `update/1`.
- **llama-server is reachable in mDNS but TCP-unreachable** — discovery still registers the ad. Dispatch failure surfaces at first call; that's a separate concern (liveness-by-binding eviction is a deferred follow-on spec).

## Out of scope

- `:generate` consumers in the agent loop (separate plan; this lands the kind so adapters can use it).
- Capability-based routing in the dispatcher (separate plan).
- Multi-service shim (`_ollama._tcp`, `_vllm._tcp`, etc.) — the same `PortAdapter` will host them; only the Tcl source changes.
- Trained-ad lifecycle / latency-based ranking (deferred substrate spec).
- LLM call-path migration (`LLMAgent.dispatch_tool/3` → `Tool.Dispatcher`) — separate plan.

## Validation

- Unit tests: EDN codec round-trip, `Generate` behaviour shape, `OpenAIChat` adapter delegation, `PortAdapter` parses fake-shim output and registers correctly.
- Integration test (skipped in CI, `@tag :requires_avahi`): runs the real Tcl shim against a fake `avahi-browse` script in a tmpdir, asserts a `_llama._tcp` record produces a discoverable ad.
- Manual validation: with both LAN llama-server hosts visible, `LLMAgent.Tools.Discovery.find_all/1` for `coordinate: "compute.llm.chat"` returns two ads; killing one causes its ad to expire within 60s.

# Tool Discovery

**Date:** 2026-05-03
**Status:** Draft

## Overview

Tool discovery is a special case of service discovery — the same problem the field has been bad at for fifty years (Bluetooth SDP, UPnP, Jini, Bonjour, UDDI, mDNS, WS-Discovery, MCP, A2A) and the same problem cataloging systems have been bad at for fifty-five centuries. This spec designs a substrate for the LLMAgent project that takes the framing seriously: tools are remote behaviours invokable by particular protocols, advertised into a registry that admits multi-fidelity multi-source descriptions, queried by pattern, gated by structured policy, and invoked through a uniform kind-shaped interface regardless of where the implementation actually lives.

The spec is scoped narrowly. It defines the registry layer and the three-layer self-description record (operational / constraint / affordance). It defers the harder work — proxy derivation, trained-ad lifecycle, commons sharing, commons governance, in-agent Bayesian-chain affordance discovery — to follow-on specs, but it puts the substrate fields in place so those future specs can plug in as plumbing rather than redesign.

## Design Constraints

- A tool declares a **RIG coordinate** — dot-separated string, first stanza is namespace. No validation of the namespace set; coordinates are opaque strings beyond the dot-parsing convention. A future `RIGCoordinate` library can layer in validation and governance.
- **Kinds are data, not a hardcoded enum.** Six canonical kinds ship as the working set (Query, Action, Stream, Compute, Coordinate, Spawn); each is its own Elixir behaviour; new kinds are added by writing a behaviour and registering it.
- **Bindings are also data.** Five canonical adapters ship (`:module`, `:process`, `:remote`, `:mcp`, `:http`); new bindings extend the same way kinds do.
- **The registry is a curated open registry**, IETF-style in spirit. v1 imposes minimal validation; the editorial machinery is a follow-on.
- **Hybrid registration model.** Direct register for trusted callers; tuple-space announcement for any party. Same store, same query interface, same events.
- **Description must admit accumulation.** Multiple ads per coordinate, with fidelity ordering, is built in from day one — even though the trainer that produces trained ads is deferred.
- **One trust enforcement point.** The dispatcher consults the agent's policy on every invocation. No bypasses.
- **Migration is incremental, never a flag day.** New substrate stands up alongside the existing `LLMAgent.Tools` registry; tools migrate one at a time; the legacy paths are removed only when the last consumer is gone.

## Background

Three sources of background inform this design:

- The triple analogy `jobs : tasks :: policies : rules :: contexts : affordances`, with wisdom as what none of those ratios contain but all of them require. See `arch/jobs are to tasks as policy is to rules.md` for the full development.
- The RIG namespace scheme for system-wide addressable things, summarized in `~/Documents/remote.vault.001/src/097 Orders of the System/namespaces.md`. Tool discovery is treated here as a slice of that broader namespace.
- The five-decade graveyard of service discovery protocols. The shape this design borrows most directly from is Jini (executable proxy as the description) constrained by Bonjour (decentralized self-advertisement) and bidirectional like SIP/SDP capability negotiation.

## §1 — The advertisement record

A tool ad is the single artifact that lives in the registry, gets matched by queries, and carries enough information to call the tool. Multiple ads per coordinate are normal and expected: an authoritative ad from the tool's author, plus trained ads accumulated through use, plus speculative ads from probes.

```elixir
%LLMAgent.ToolAd{
  id:          binary(),                 # ad identity (uuid or content-hash)
  coordinate:  String.t(),               # "resource.network.netif"
  kinds:       [atom()],                 # [:query, :stream] — composable
  binding:     {atom(), term()} | nil,   # how to invoke; nil for pure-speculative ads

  operational: %{
    actions: %{
      action_name => %{
        inputs:  schema_term(),
        outputs: schema_term(),
        pre:     term(),
        post:    term()
      }
    }
  },

  constraint: %{
    auth:         term(),
    rate:         term(),
    idempotency:  %{action => atom()},   # :idempotent | :non_idempotent | :unknown
    blast_radius: %{action => atom()},   # :pure | :local | :system | :external | :unknown
    sequencing:   term(),
    retry:        term()
  } | {:ref, String.t()},                # OR a reference to a policy.* coordinate

  affordance: %{
    declared: [%{intent: String.t(), suits: String.t(), avoid_when: String.t() | nil}],
    learned:  [...],                     # shape deferred to trained-ad lifecycle spec
    open:     boolean()                  # "discoverable through interaction"
  },

  fidelity:    :authoritative | :trained | :speculative,
  confidence:  float() | nil,            # for trained/speculative; nil for authoritative

  provenance: %{
    source:      term(),
    produced_at: DateTime.t(),
    based_on:    [ad_id_or_observation_ref],
    signature:   binary() | nil
  },

  lease:       :permanent | {:expires_at, DateTime.t()},
  meta:        map()
}
```

### Field notes

- **coordinate** — opaque string with the dot-parsing convention. No validation of namespace set.
- **kinds** — composable list. The kind registry is open and data-driven (§3.8). An ad may declare a kind not currently in the local registry; it will still be stored, but un-callable until the kind is registered.
- **binding** — `{kind, payload}`. The binding kind is recognized via the bindings registry (§4.4). May be `nil` for speculative ads with no callable handle yet.
- **operational** — what the tool does mechanically (inputs, outputs, pre/post). Schemas live here. This is the layer MCP, OpenAPI, and tool-call schemas all solve.
- **constraint** — what governs use, not what the tool does. Per-action idempotency and blast-radius are explicit because the agent reasons about retry/verify/effect very differently across actions of the same tool. Constraint may also be a `{:ref, coordinate}` pointing to a `policy.*` ad, allowing constraint factoring across tools.
- **affordance** — relational, partially declared, partially learned. The `declared` list is author hints (intent → suitability). The `learned` list is filled by trainers in a follow-on spec. The `open` flag honestly says "treat this tool's affordance space as partially discoverable through interaction."
- **fidelity / confidence / provenance** — the registry is multi-source. These fields let the resolver rank candidates and let policy filter on origin.
- **lease** — `:permanent` for registered, `{:expires_at, ts}` for announced. Same record, lease field discriminates.
- **based_on** — for trained ads, records what evidence/observations/prior ads informed this one. The format is deferred but the field is here so the substrate doesn't need to change later.

### What this commits to

1. Affordance is its own structured layer, not a string field collapsed next to schemas.
2. Description fidelity is first-class; multiple ads per coordinate are normal.
3. The shape doesn't pretend completeness — `affordance.open` lets authors honestly defer.
4. Provenance/identity hooks are in place; the commons protocol is not.

## §2 — Discovery query semantics

Queries match by pattern over (coordinate, kinds, constraint requirements, fidelity, provenance). Subscriptions get notified on changes.

### Query record

```elixir
%LLMAgent.ToolQuery{
  coordinate:   String.t(),       # "resource.network.*" — exact or prefix-glob
  kinds:        :any | [atom()],  # all listed must be present; :any matches any
  fidelity_min: :speculative | :trained | :authoritative,  # default :speculative
  constraint:   map() | nil,
  provenance:   map() | nil,
  limit:        pos_integer() | :all
}
```

### Coordinate matching

- Exact match on bare strings (`"function.crypto.sha256"`).
- Prefix-glob with trailing `*` (`"resource.network.*"` matches `"resource.network.netif"`, `"resource.network.dns.cache"`, etc.).
- No middle-globs, no regex. Expand only when a concrete need shows up.
- The set of valid first stanzas is not enforced.

### Result shape

`{:ok, [%ToolAd{}]}` ranked by:

1. fidelity (`authoritative` > `trained` > `speculative`)
2. confidence descending (within trained/speculative)
3. `produced_at` descending (recency tiebreaker)

A convenience `find_one/1` returns the head. **No silent merging** — if authoritative and trained ads disagree on operational shape, both come back; merging is a higher-layer concern, deferred to the trained-ad lifecycle spec.

### Subscriptions

```elixir
LLMAgent.Tools.Discovery.subscribe(query, subscriber_pid)
```

Subscribers receive:

- `{:tool_added, ad_id, coordinate}`
- `{:tool_updated, ad_id, coordinate}`
- `{:tool_removed, ad_id, coordinate, reason}` where `reason ∈ {:unregistered, :lease_expired, :evicted}`

The registry filters at subscription time so subscribers only see matching events. Subscriptions auto-clean on subscriber death (the registry monitors the pid).

### Storage

ETS table keyed on `ad_id`, with secondary indexes on `coordinate` (for prefix scans), `kinds`, and `fidelity`. Owned by `LLMAgent.Tools.Discovery` GenServer, which mediates writes and serves reads via direct ETS access for hot paths.

### Tuple-space relationship

Announcements arrive as `{:tool_announce, ad_id, %ToolAd{}}` tuples. Discovery has a long-lived `in/2` consumer on that pattern and absorbs announcements into the registry. Direct registration writes to the registry directly. Same query interface either way.

### Lease eviction

A periodic sweeper (default 30s, configurable) walks the registry, removes ads whose lease has expired, and emits `:tool_removed` events with reason `:lease_expired`.

### What this commits to

1. Pattern grammar is tiny — exact + prefix-glob.
2. No silent picks, no silent merges. Ranked candidates out; agent policy chooses.
3. Subscriptions are first-class — Jini-style watch with auto-cleanup, not "go poll."

## §3 — Kind contracts

Each kind is its own Elixir behaviour with focused callbacks. A tool declares one or more `@behaviour` lines; the dispatcher routes by `(kind, action)`.

### §3.0 — Umbrella behaviour

Every tool implements one parent behaviour that produces its authoritative ad:

```elixir
defmodule LLMAgent.Tool do
  @callback ad() :: %LLMAgent.ToolAd{}
end
```

The current `describe/0`/`perform/2` shape is retired — affordance description lives in the ad, invocation is per-kind.

### §3.1 — `:query`

Pure read. No observable side effects. Idempotent. Freely retryable. May do I/O — that distinguishes it from `:compute`. Cacheable on `(module, action, args)` only with the tool's consent (queries can return time-varying values).

```elixir
defmodule LLMAgent.Tool.Kinds.Query do
  @callback query(action :: String.t(), args :: map()) ::
              {:ok, value :: term(), meta :: map()}
            | {:error, term()}
end
```

Examples: `Net`, `Proc`, `File.read`, `Web.get`.

### §3.2 — `:action`

Causes side effects. NOT safely retryable without an idempotency key. Agent must verify outcome before declaring success.

```elixir
defmodule LLMAgent.Tool.Kinds.Action do
  @callback act(
              action :: String.t(),
              args :: map(),
              idempotency_key :: String.t() | nil
            ) :: {:ok, ack :: term(), meta :: map()} | {:error, term()}
end
```

The key is mandatory in the signature but may be `nil` for actions that don't support it. The constraint section says which actions honor keys.

Examples: `Bash`, `Systemd.restart`, `File.write`, `Web.post`.

### §3.3 — `:stream`

Subscribe → ongoing events → unsubscribe. The tool monitors the subscriber pid and auto-closes on death. Backpressure is the subscriber's responsibility; the tool may drop or close on overflow and must declare its policy.

```elixir
defmodule LLMAgent.Tool.Kinds.Stream do
  @callback subscribe(
              action :: String.t(),
              args :: map(),
              subscriber :: pid()
            ) :: {:ok, sub_ref :: reference()} | {:error, term()}

  @callback unsubscribe(sub_ref :: reference()) :: :ok
end
```

Subscriber receives `{:stream_event, sub_ref, event}` and `{:stream_closed, sub_ref, reason}`.

Examples: `Inotify`, `Udev`, log tails.

### §3.4 — `:compute`

Pure transformation. **No I/O of any kind.** Deterministic given inputs. Freely retryable, freely cacheable, freely movable to any node.

```elixir
defmodule LLMAgent.Tool.Kinds.Compute do
  @callback compute(action :: String.t(), args :: map()) ::
              {:ok, value :: term()} | {:error, term()}
end
```

No `meta`, no idempotency key, no monitoring — there's nothing for those to mean. If your tool needs any of them, it's `:query` or `:action`, not `:compute`.

Examples: `Crypto`, parsers, formatters, transforms.

### §3.5 — `:coordinate`

Multi-party interaction over a shared substrate. Meaning depends on who else is at the table. Often paired with `:query` and `:action` on the same coordinate (e.g., TupleSpace is `:coordinate` for `out`, `:query` for `rd`).

```elixir
defmodule LLMAgent.Tool.Kinds.Coordinate do
  @callback participate(
              role :: atom(),
              args :: map(),
              opts :: keyword()
            ) :: {:ok, participation_ref :: reference()} | {:error, term()}

  @callback leave(participation_ref :: reference()) :: :ok
end
```

`role` is the well-known interaction role for this coordination kind (e.g., `:publisher`, `:subscriber`, `:writer`, `:reader`). Roles are documented per-tool in the ad.

Examples: `TupleSpace`, `DBus`, NATS pubsub, distributed registry.

### §3.6 — `:spawn`

Bring up another process or agent. Parent owns the child's lifecycle. Child's exit is observable to the parent. Parent's exit cascades or orphans per opts.

```elixir
defmodule LLMAgent.Tool.Kinds.Spawn do
  @callback spawn_child(spec :: term(), opts :: keyword()) ::
              {:ok, child_ref :: term()} | {:error, term()}

  @callback child_status(child_ref :: term()) :: term()

  @callback terminate_child(child_ref :: term(), reason :: term()) ::
              :ok | {:error, term()}
end
```

Examples: existing `Agent` tool, generic process spawners.

### §3.7 — Composition rules

- A tool may declare multiple kinds with multiple `@behaviour` lines. The ad's `kinds` list is the authoritative enumeration.
- Each kind has its own callback namespace; no collision between, say, `query/2` and `act/3`.
- A single action name may exist under more than one kind on the same tool — the dispatcher routes by `(kind, action)`, not action alone.

### §3.8 — Kind registry

The set of valid kinds is open and data-driven, per the same principle as RIG namespaces:

- `LLMAgent.Tool.Kinds` exposes `register_kind(name, behaviour_module)` and `list_kinds/0`.
- The framework seeds the canonical six on startup.
- Adding a kind is "write a behaviour module, register it."
- Kind validation in ads is permissive: an ad may declare a kind not currently in the local registry. Such ads are stored (with a flag), but the dispatcher refuses to invoke the unknown kind until its behaviour is registered.

### What §3 commits to

1. Per-kind callbacks, not unified perform. Semantic separation prevents `:compute` invariants from being violated by a `:query` that does I/O.
2. The tool's authoritative ad lives in code (`ad/0`).
3. Open kind registry. Six is the working set; expansion is data, not a framework version bump.

## §4 — Binding & invocation adapters

Once the agent has picked an ad, the dispatcher invokes through the binding's adapter. Every tool — local module, remote process, HTTP endpoint, MCP server — is invoked through the same kind-shaped interface from the agent's perspective.

### §4.1 — Adapter behaviour

```elixir
defmodule LLMAgent.Tool.Adapter do
  @callback query(payload :: term(), action :: String.t(), args :: map(),
                  opts :: keyword()) ::
              {:ok, term(), map()} | {:error, term()}

  @callback act(payload :: term(), action :: String.t(), args :: map(),
                idempotency_key :: String.t() | nil, opts :: keyword()) ::
              {:ok, term(), map()} | {:error, term()}

  @callback subscribe(payload :: term(), action :: String.t(), args :: map(),
                      subscriber :: pid(), opts :: keyword()) ::
              {:ok, reference()} | {:error, term()}

  @callback unsubscribe(payload :: term(), sub_ref :: reference(),
                        opts :: keyword()) :: :ok

  @callback compute(payload :: term(), action :: String.t(), args :: map(),
                    opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @callback participate(payload :: term(), role :: atom(), args :: map(),
                        opts :: keyword()) ::
              {:ok, reference()} | {:error, term()}

  @callback leave(payload :: term(), participation_ref :: reference(),
                  opts :: keyword()) :: :ok

  @callback spawn_child(payload :: term(), spec :: term(), opts :: keyword()) ::
              {:ok, child_ref :: term()} | {:error, term()}

  @callback child_status(payload :: term(), child_ref :: term(),
                         opts :: keyword()) :: term()

  @callback terminate_child(payload :: term(), child_ref :: term(),
                            reason :: term(), opts :: keyword()) ::
              :ok | {:error, term()}

  @optional_callbacks query: 4, act: 5, subscribe: 5, unsubscribe: 3, compute: 4,
                      participate: 5, leave: 3, spawn_child: 4, child_status: 3,
                      terminate_child: 4
end
```

Each callback mirrors its kind's contract with one extra arg up front: the binding payload. Adapters implement only the kinds their binding supports. An adapter that doesn't implement a kind raises a clear "binding kind X cannot carry kind Y" error if invoked.

### §4.2 — Initial adapters

- **`:module`** — Payload is a module implementing the kind behaviours directly. Adapter calls are straight `apply/3` pass-throughs. Used for in-process tools.
- **`:process`** — Payload is a `pid()`, `{:via, registry, name}`, or local registered name. Adapter wraps each call as a `GenServer.call` with a tagged tuple and the configured timeout.
- **`:remote`** — Payload is `{node, name}`. Same protocol as `:process` but routed across the cluster. On `:noproc` or `:nodedown`, returns `{:error, :unreachable}`.
- **`:http`** — Payload is `%{url, method_map, auth, encoders}`. The adapter builds and sends an HTTP request. Only `:query` and `:action` initially. SSE/chunked streaming is a follow-on.
- **`:mcp`** — Payload is `{server_ref, tool_name}`. Routes through the existing MCP client. Maps MCP's tool model onto kinds: every MCP tool is at minimum `:action`; tools known to be safe can be tagged `:query` in their ad. MCP doesn't natively support `:stream`/`:coordinate`/`:spawn`.

### §4.3 — Dispatcher

```elixir
defmodule LLMAgent.Tool.Dispatcher do
  def query(ad_or_coordinate, action, args, opts \\ [])
  def act(ad_or_coordinate, action, args, idempotency_key \\ nil, opts \\ [])
  def subscribe(ad_or_coordinate, action, args, subscriber_pid, opts \\ [])
  # ... one function per kind callback
end
```

For each call:

1. **Resolve.** Coordinate → discovery query for the best ad satisfying the agent's policy. Already-an-ad → use directly.
2. **Trust check.** Consult the agent's policy (§6). Fail closed.
3. **Kind check.** Verify the requested kind is in the ad's `kinds` list.
4. **Adapter lookup.** Resolve binding-kind atom to adapter module via the bindings registry.
5. **Invoke.** Call the adapter's matching callback with the binding payload.
6. **Emit telemetry.** `[:llmagent, :tool, kind, action]` with provenance/fidelity in metadata.

The dispatcher is the choke point for trust, observability, and policy. It is not the choke point for retry, caching, or circuit-breaking — those are higher-layer concerns.

### §4.4 — Bindings registry

Parallel to the kinds registry:

- `LLMAgent.Tool.Bindings.register(name, adapter_module)` and `list_bindings/0`.
- Framework seeds the five canonical bindings on startup.
- Adding a binding kind is "write an adapter, register it."
- Ads referencing an unregistered binding kind are stored but un-callable.

### §4.5 — Trust integration

The existing `allowed_tools` policy is generalized to a structured `%LLMAgent.Tool.Policy{}` (§6). The dispatcher consults this in step 2.

### §4.6 — What's deliberately not here

- Retry / circuit-breaker / caching middleware. Adapters propagate errors; wrapping middleware is an agent-side concern.
- HTTP streaming (SSE, chunked). Initial `:http` adapter is request/response only.
- Liveness-by-binding eviction. Dispatcher reports `:unreachable`; ad is not evicted.
- WASM proxies. The natural extension of this layer (a `:wasm` binding kind whose payload is a proxy artifact) is recorded as a follow-on; not in v1.

### What §4 commits to

1. Adapters are per-binding, kind-shaped. Every tool looks like a kind-conforming callee from the agent's side.
2. The dispatcher is the trust + observability choke point.
3. Adding a new binding kind is data.

## §5 — Registration & announcement protocol

Two paths into the registry: **direct** for in-process or trusted callers, **announcement** via tuple space for any party. Both produce identical ads in the same store.

### §5.1 — Direct registration API

```elixir
LLMAgent.Tools.Discovery.register(ad :: %ToolAd{}) :: :ok | {:error, term()}
LLMAgent.Tools.Discovery.update(ad :: %ToolAd{})   :: :ok | {:error, term()}
LLMAgent.Tools.Discovery.unregister(ad_id :: binary()) :: :ok
LLMAgent.Tools.Discovery.renew(ad_id, new_expiry)  :: :ok | {:error, :not_found}
```

Builtin tools register at application start; each tool's `ad/0` callback produces its authoritative ad.

### §5.2 — Announcement via tuple space

Any party can announce a tool:

```text
{:tool_announce, ad_id, %ToolAd{}}
{:tool_withdraw, ad_id}
```

Discovery runs a long-lived consumer that does `in/2` on these patterns. Same validation, same events, same registry storage. Re-announcement with the same `ad_id` is the renewal mechanism. At-least-once delivery from the tuple space is safe (re-announcement of an unchanged ad is idempotent).

### §5.3 — Validation

At registration:

- `coordinate` non-empty, contains at least one `.`-separated stanza.
- `kinds` non-empty list of atoms.
- `binding` either `nil` or `{atom, term}`.
- `fidelity ∈ {:authoritative, :trained, :speculative}`.
- `provenance.source` set; `provenance.produced_at` is a `DateTime`.
- `lease` is `:permanent` or `{:expires_at, future DateTime}`.

On failure: `{:error, {:invalid_ad, field, reason}}`. No best-effort fixups.

### §5.4 — Lease renewal and eviction

`:permanent` ads stay until unregistered. `{:expires_at, ts}` ads must be renewed before `ts` or evicted. For directly-registered ads, call `renew/2`. For announced ads, re-announce with the same `ad_id`.

### §5.5 — Updates and identity

Same `ad_id` → update (in-place replacement). Different `ad_id` → addition. The producer chooses by reusing or rolling the id. The "same ad" question is answered by `id` equality, not by deep field comparison.

### §5.6 — Persistence and restart

v1: in-memory ETS owned by `LLMAgent.Tools.Discovery`. Restart behaviour:

- Builtin tools re-register at application start.
- Announced tools recover when their next announcement arrives.
- Subscribers must monitor Discovery and re-subscribe on restart.

DurableLog-backed persistence is a v2 follow-on aligned with the trained-ad commons.

### §5.7 — Identity and signing (deferred)

`provenance.signature` exists as a field; nothing in v1 verifies it. Policies can filter by `provenance.source` as a string match — honor-system within a trust boundary. Real signing is the commons-governance follow-on.

### §5.8 — What's deliberately not here

- DurableLog-backed persistence.
- Signature verification.
- Conflict resolution between competing trained ads.
- Bulk/batch registration.
- Acknowledgement protocol for announcements.

### What §5 commits to

1. Direct and announcement paths produce identical ads.
2. Renewal is re-assertion. No separate heartbeat protocol.
3. In-memory v1, durable-and-governed v2.

## §6 — Trust / policy integration

The existing `allowed_tools` whitelist generalizes to a structured policy that gates the dispatcher.

### §6.1 — Policy struct

```elixir
%LLMAgent.Tool.Policy{
  allow:        [policy_rule()],
  deny:         [policy_rule()],
  fidelity_min: :authoritative | :trained | :speculative,  # default :trained
  provenance:   %{
                  source: [String.t()] | :any,    # default :any
                  signed: boolean()               # default false (inert in v1)
                } | nil
}

@type policy_rule :: %{
  coordinate: String.t(),
  kinds:      :any | [atom()],
  actions:    :any | [String.t()]
}
```

Bare-string convenience: a string desugars to `%{coordinate: <str>, kinds: :any, actions: :any}`.

### §6.2 — Decision algorithm

The dispatcher consults the policy with `(ad, kind, action)`:

1. If any `deny` rule matches → `{:error, :forbidden, :explicit_deny}`. Denies always win.
2. If no `allow` rule matches → `{:error, :forbidden, :not_allowed}`. Deny-by-default.
3. If `ad.fidelity` < `fidelity_min` → `{:error, :forbidden, :fidelity_too_low}`.
4. If `provenance.source` is a list and `ad.provenance.source` is not in it → `{:error, :forbidden, :provenance}`.
5. If `provenance.signed: true` and `ad.provenance.signature == nil` → `{:error, :forbidden, :unsigned}`. (v1: never fires; path is wired so v2 plugs in the verifier.)
6. Otherwise → allowed.

### §6.3 — Per-call override

Any dispatcher call accepts an optional `policy:` opt that further restricts the effective policy. The effective policy is the **intersection** of the standing policy and the call-specific one. Per-call policies can only narrow.

### §6.4 — Spawn inheritance

When an agent spawns a child via `:spawn`, the child's policy is bounded above by the parent's. Default: child inherits parent verbatim. Spawn opts may pass `child_policy:` to restrict further. Attempts to broaden are silently narrowed.

### §6.5 — Migration from current `allowed_tools`

The flat list `[:bash, :web]` is interpreted as:

```elixir
%Policy{
  allow: [
    %{coordinate: "legacy.bash", kinds: :any, actions: :any},
    %{coordinate: "legacy.web",  kinds: :any, actions: :any}
  ],
  fidelity_min: :authoritative,
  provenance:   %{source: :any, signed: false}
}
```

The `legacy.*` prefix is a placeholder until §7 assigns real coordinates. Both forms are accepted during migration.

### §6.6 — What's deliberately not here

- Signature verification (hooked, inert).
- Capability tokens / OAuth scopes.
- Rate limiting / cost budgets (declared in ad's constraint section; enforcement is wrapping middleware).
- Policy-as-ad (`policy.*` coordinates with policies as first-class registry citizens).
- Audit log construction (telemetry captures the data; building a queryable log is downstream).

### What §6 commits to

1. One enforcement point — the dispatcher.
2. Deny-by-default, deny-wins.
3. Per-call narrowing, never broadening. Parent → child likewise.

## §7 — Migration from current `LLMAgent.Tools`

Strategy is incremental — additive first, subtractive last. New substrate stands up alongside the existing `persistent_term`-backed registry; tools migrate one at a time; old API keeps working until the last consumer is gone.

### §7.1 — Strategy

1. Add new modules (structs, behaviours, Discovery, Dispatcher, Policy, Adapters) as pure additions.
2. Add a coexistence shim so legacy `LLMAgent.Tools.get/1` consults Discovery first, falls back to the old table.
3. Migrate tools one at a time. Each migration is a single PR.
4. Migrate the agent's `dispatch_tool` path to use Dispatcher + Policy.
5. Once all builtins are migrated and no consumer uses the legacy paths directly, remove them.

The tree stays green at every commit.

### §7.2 — Proposed coordinate assignments

Coordinates aren't load-bearing for v1 (they're opaque per scope) and can be revisited when RIG validation lands. The convention follows the `function.` / `resource.` split from the namespaces note.

| Tool | Coordinate | Kinds |
| --- | --- | --- |
| `Bash` | `function.shell.bash` | `[:action]` |
| `Web` | `function.http` | `[:query, :action]` |
| `DBus` | `function.dbus` | `[:coordinate, :query, :action]` |
| `Systemd` | `function.systemd` | `[:query, :action]` |
| `File` | `resource.fs.file` | `[:query, :action]` |
| `Inotify` | `resource.fs.events` | `[:stream]` |
| `Udev` | `resource.hardware.events` | `[:stream]` |
| `Net` | `resource.network` | `[:query]` |
| `Proc` | `resource.proc` | `[:query]` |
| `Crypto` | `function.crypto` | `[:compute]` |
| `TupleSpace` | `function.coordination.tuplespace` | `[:coordinate, :query, :action]` |
| `Agent` | `function.agent` | `[:spawn]` |

`Web` stays a single tool with two kinds (GET/HEAD/OPTIONS under `:query`; POST/PUT/DELETE/PATCH under `:action`). `File` likewise. `TupleSpace` is the most-composed: `out`/`in`/`take` under `:coordinate` (or `:action` for destructive `take`); `rd`/`rd_nowait` under `:query`. Action-to-kind mapping is settled per-tool in the migration PR.

### §7.3 — Per-tool migration shape

```elixir
defmodule LLMAgent.Tools.Bash do
  @behaviour LLMAgent.Tool                # umbrella
  @behaviour LLMAgent.Tool.Kinds.Action

  @impl LLMAgent.Tool
  def ad do
    %LLMAgent.ToolAd{
      id:          "builtin.bash",
      coordinate:  "function.shell.bash",
      kinds:       [:action],
      binding:     {:module, __MODULE__},
      operational: %{actions: %{"run" => %{...}}},
      constraint:  %{
        idempotency:  %{"run" => :non_idempotent},
        blast_radius: %{"run" => :system}
      },
      affordance: %{declared: [...], learned: [], open: false},
      fidelity:   :authoritative,
      provenance: %{source: "llmagent.builtin", produced_at: ~U[...], signature: nil},
      lease:      :permanent,
      meta:       %{}
    }
  end

  @impl LLMAgent.Tool.Kinds.Action
  def act("run", %{"cmd" => cmd}, _idempotency_key) do
    # current implementation
  end

  # Backwards-compat shim — kept until callers migrate.
  def perform("run", args), do: act("run", args, nil)
end
```

### §7.4 — Coexistence shim

`LLMAgent.Tools.get/1` consults Discovery first, falls back to the legacy table. A small `legacy_coordinate_for/1` map populates as tools migrate. When a tool migrates, its entry moves to Discovery in the same PR.

### §7.5 — Agent dispatch path

The current `dispatch_tool` migrates to `Dispatcher.invoke(coordinate_or_name, kind, action, args, policy, opts)`. `Policy.from_legacy_or_struct/1` accepts both `[:bash, :web]` and `%Policy{}` and produces a normalized policy.

### §7.6 — Order of operations

1. Substrate (new modules, Discovery, Dispatcher, Policy, five adapters).
2. First migration: `Crypto` (simplest case: pure `:compute`).
3. Pure-query tools: `Net`, `Proc`.
4. Stream tools: `Inotify`, `Udev`.
5. Mixed tools: `File`, `Web`, `Systemd`, `DBus`.
6. Complex tools: `TupleSpace`, `Agent`.
7. `Bash` (last because of blast radius).
8. Agent dispatch path migration.
9. LLM-facing catalog regeneration — system prompt switches from name-keyed schemas to coordinate-keyed ads.
10. Subtraction: remove `perform/2` shims, the persistent_term table, the legacy coordinate map, the deprecated `describe/0` callback.

Each step is a small PR.

### §7.7 — What's removed and when

Deprecated immediately (still works, warnings on use):

- `LLMAgent.Tool` callback `describe/0`.
- `LLMAgent.Tool` callback `perform/2`.
- `LLMAgent.Tools.register/2`/`unregister/1` with module values.
- Flat-list `allowed_tools`.

Removed at the end of migration:

- The `:persistent_term` registry table.
- The compat shim in `LLMAgent.Tools.get/1`.
- The `Policy.from_legacy_or_struct/1` translator.
- All `perform/2` shims in tool modules.

### What §7 commits to

1. Incremental, never a flag day.
2. Coordinate names are seed convention, not contract.
3. Subtraction is its own work, after migration completes.

## Follow-on specs

The following are explicitly out of scope here and will be designed separately. Their substrate hooks are in this spec.

1. **Three-layer self-description protocol for external services.** Generalize the OPTIONS-returns-spec idea so non-llmagent services publish operational + constraint + affordance over their own protocol. The obvious mechanism is `OPTIONS <resource>` returning a structured document.
2. **Trained-ad lifecycle and proxy-derivation toolchain.** The case-B → case-A migration. How an agent or trainer accumulates a posterior into a trained ad. Includes the `affordance.learned` shape and the trainer process.
3. **Commons storage and sharing protocol.** How trained ads move between hosts, conflict resolution, attestation. The "open commons" the framing doc says must not be enclosed.
4. **Commons governance.** Rules of contribution, conflict resolution, quality thresholds, protection from capture by well-resourced actors. Co-equal design problem with the technical commons protocol.
5. **In-agent Bayesian chain / RL-satisficing exploration.** How an agent uses an `affordance.open` ad to discover fit through interaction. Memory across episodes, posterior carry-forward, satisficing termination.
6. **WASM-binding adapter.** A `:wasm` binding kind whose payload is a proxy artifact. Jini done correctly.
7. **DurableLog-backed registry persistence.** Replay of register/update/unregister events at startup. Aligned with the trained-ad commons.
8. **Liveness-by-binding eviction.** Auto-removal of ads whose bindings are observably unreachable.
9. **Policy-as-ad.** First-class `policy.*` coordinates with policies registered like tools. Hooked via `constraint: {:ref, coordinate}`.
10. **HTTP streaming adapter.** SSE / chunked response support for `:stream` over `:http`.
11. **RIG coordinate validation library.** Parsing, validation, governance of the namespace set.

## Open questions

These were noted during design but not resolved; they don't block implementation.

- Default `fidelity_min` is `:trained`, not `:authoritative`. Reasoning: in v1 only authoritative exists, so the default is functionally moot, but choosing `:trained` now means default behaviour is sane when the commons arrives. Stricter default is a one-line change.
- `legacy_coordinate_for/1` map is a transitional artifact. Could be eliminated by requiring callers to switch to coordinates immediately when a tool migrates, but at the cost of a stricter per-tool cutover. Kept for migration cushion.
- Whether `:coordinate` should split into sub-behaviours (`:coordinate.pubsub`, `:coordinate.rendezvous`). Not in v1; revisit if patterns emerge.
- MCP-imported tools' migration is a parallel track. Not part of the §7 sequence; flagged.

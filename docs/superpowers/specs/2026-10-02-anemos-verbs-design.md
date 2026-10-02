# The substrate as Anemos's verb library

**Date:** 2026-10-02 · **Branch:** `anemos-verbs` · item 2 of the Anemos program

## Problem

An Anemos policy acts through `[MODULE::verb args]`, and every module has to
be an Elixir module the host wrote and registered by hand. The substrate
already knows what this machine can do: every `%ToolAd{}` in
`LLMAgent.Tools.Discovery` is a tool with a coordinate, actions, kinds, and
per-action idempotency and blast radius, and `LLMAgent.Tool.Dispatcher`
already decides, under a `%Policy{}`, whether a caller may use it. None of
that reaches a policy.

## Design

`LLMAgent.Anemos` is one Anemos module that stands behind every discovered
tool. Started as a child next to the runtime:

```elixir
{Anemos.Runtime, name: :anemos, watch: "/etc/anemos/policies"},
{LLMAgent.Anemos, runtime: :anemos, policy: %LLMAgent.Tool.Policy{allow: ["resource.*"]}}
```

### Names

A coordinate becomes a module name by uppercasing and replacing dots with
underscores: `resource.net` is `[RESOURCE_NET::ping ...]`, `compute.llm.chat`
is `[COMPUTE_LLM_CHAT::chat ...]`. Actions are verbs as they are.

Every ad in the registry at start, and every ad that arrives after, is
registered under its name with the runtime. An ad that leaves is not
unregistered — the registry is write-once — and a call to it fails at
dispatch with `:not_found`, which is the truth.

### Arguments

Tool actions take a map; a policy writes key-value pairs:

```text
[RESOURCE_NET::ping :host "skynet001.local"]
```

An atom reaches a verb as a string, so the rule is positional: even
positions are keys, odd positions values, and an odd-length argument list
is refused before anything is dispatched.

### Dispatch

Every call goes through `LLMAgent.Tool.Dispatcher` under the `%Policy{}` the
attachment was started with. No policy, no calls: the dispatcher's default
denies everything. The kind is chosen from what the ad declares, in the
order `:query`, `:compute`, `:generate`, `:action` — the side-effect-free
kinds first — and a kind that answers `:unknown_action` or
`:kind_not_supported` yields to the next. Results are flattened to
`{:ok, value}`; a query's metadata and a generation's provenance are
dropped at this boundary.

`:stream` (subscriptions) is item 3, events. `:coordinate` and `:spawn` are
not reachable from a policy.

### Metadata

`LLMAgent.Anemos.verbs/0` lists every verb a policy could call, with its
coordinate, kinds, idempotency and blast radius — what agento's rules view
and a future `explain` can show next to the rule that calls it.

### Everything

`ToolQuery` gained a pattern: `"*"` alone matches every coordinate. It is
what the attachment subscribes with. The same vocabulary is used by
`%Policy{}` rules, so `allow: ["*"]` now means everything, where before it
silently matched nothing.

### What the review added

- A tool runs in its own process with a deadline (`:verb_timeout_ms`,
  default 4000). Raise, exit, re-entry into the runtime, or a slow call all
  come back to the rule as `{:error, _}`; the dispatcher is never the
  casualty.
- The attachment is the authority: a verb asks it, per call, for the policy
  and the coordinate behind its name. Stopped attachment, `{:error, :detached}`.
- A name keeps its first coordinate until that coordinate leaves. A later
  coordinate that maps to the same name is warned about and not reachable.
- `require_approval` rules are refused at start: nothing can answer.

### Amended by item 3

`LLMAgent.Anemos` became a supervisor over `LLMAgent.Anemos.Tools` (what
this spec describes) and `LLMAgent.Anemos.Events`; see
`2026-10-02-anemos-events-design.md`.

## Rulings

1. **The bridge lives in llmagent**, which now depends on anemos. The
   language stays free of the substrate; the substrate knows the language.
2. **One policy per attachment.** A runtime that needs different tool
   rights for different tenants is two runtimes, or waits for the load
   authority to carry policy — not this spec.
3. **Idempotency keys are not sent.** Nothing in a rule firing identifies
   the logical operation yet.
4. **An ad is registered whether or not the policy admits it.** The
   refusal happens at the call and is reported to the rule.

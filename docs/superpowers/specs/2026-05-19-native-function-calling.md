# Native function-calling and Comn alignment course-correction

**Date:** 2026-05-19
**Status:** Draft
**Triggered by:** T17 end-to-end run against skynet001 (gemma-4-26B), 2026-05-18.

## Overview

The tool-substrate migration sweep (§7.2–§7.8 of `2026-05-03-tool-discovery-design.md`) shipped on 2026-05-18, putting every native tool behind a `%ToolAd{}` with kind-specific callbacks and routing the agent's dispatch path through `Tool.Dispatcher` with a structured `%Policy{}`. T17 verified the plumbing end-to-end against a real LAN llama (gemma-4-26B on skynet001 via mDNS-discovered ad). The plumbing worked. The model didn't.

What broke is the **tool-call serialisation contract between the LLM and the agent loop**. The current contract is informal: the agent expects the model to emit a single JSON object as the entire content of an assistant message, with keys `"tool"`, `"action"`, `"args"`. Gemma-26B emitted the same JSON but wrapped in a markdown code fence — the parser saw ``` ` ` ` ` ` ` ```json {…} ``` ` ` ` ``` instead of `{…}`, declared `is_tool_call: false`, and the loop terminated without dispatching anything. No telemetry fired. No tool ran.

This is the structural gap between "we have a substrate that knows what tools exist" and "the model actually uses it." The OpenAI Chat Completions API defines a native function-calling mechanism that closes this gap for any conforming OpenAI-compatible endpoint, **including llama.cpp's `llama-server`**, which has supported it since mid-2024 with grammar-constrained decoding. We're not using it.

This spec is the design for adopting it, AND for course-correcting two pieces of architectural debt that the migration sprint either created or failed to retire: (a) input schemas live nowhere coherent yet — the migration shipped empty `inputs: %{}` everywhere, and the function-calling work needs them; (b) the substrate underuses Comn, the dependency it sits on. The cheapest moment to fix both is now, before the function-calling implementation hardens around the wrong defaults. Phase 1 of this spec ships native function-calling + behaviour-driven schemas + Comn alignment as one coherent course-correction. Phase 2 deferral covers the broader Comn folding that doesn't block the function-calling work.

## Background — what just happened

The T17 script started an `LLMAgent` GenServer pointed at `http://10.10.1.226:8080` (skynet001) with model `gemma-4-26B-A4B-it-Q4_K_M.gguf`, sent the prompt:

> Compute the SHA-256 hash of the string "abc" by calling the crypto tool. Respond with a single tool call in JSON of the form:
> `{"tool": "crypto", "action": "sha256", "args": {"data": "abc"}}`

and subscribed to `agent.message` events. The captured exchange:

```text
[agent.message user]      Compute the SHA-256 hash of the string "abc"...
[agent.llm_response]      is_tool_call=false
[agent.message assistant] ```json {"tool": "crypto", "action": "sha256", "args": {"data": "abc"}} ```
(loop terminates — no tool dispatch, no telemetry)
```

The model produced the correct intent. The agent couldn't read it because of two characters of markdown framing it didn't ask the model to omit. This is not a bug in gemma. It's a brittle contract.

## §1 — The current mechanism (anatomy)

The contract has three load-bearing parts, all in `lib/LLMAgent.ex`:

### 1.1 — Where the contract is communicated to the model

It isn't. `RolePrompt.get(:default)` returns the literal string `"You are a helpful assistant."` There is no system-prompt section enumerating available tools, no list of action names, no schemas, no example of the expected output format. The model is expected to either already know the protocol from training (it doesn't) or to be told the format by the user inline (T17's prompt did so, and gemma still framed the output as a code block).

### 1.2 — Where the tool call is extracted from the response

`lib/LLMAgent.ex` `parse_tool_call/1` (line 274) and `tool_call?/1` (line 284):

```elixir
defp parse_tool_call(content) do
  case Jason.decode(content) do
    {:ok, %{"tool" => tool, "action" => action, "args" => args}} ->
      {:tool_call, String.to_atom(tool), action, args}

    _ ->
      :not_a_tool_call
  end
end
```

The entire `content` string must be JSON-decodable AND have the three required keys. Any leading whitespace, prose, code fence, or trailing explanation makes the decode fail. The decode is the only check — there is no fallback regex, no leniency, no markdown stripping, no LLM-specific shim.

### 1.3 — Where the tool result is fed back to the model

After dispatch, `format_tool_result/1` (line 291) JSON-encodes a `%{status, output, metadata}` map and the agent appends it to history as `%{role: "function", content: <json>}`. The `"function"` role predates OpenAI's `"tool"` role and is the original deprecated form from the function-calling beta of 2023; current OpenAI APIs use `"tool"` with a `tool_call_id` field.

### Why this contract was reasonable for v0

Sonnet/Opus/GPT-4 follow free-form JSON instructions almost perfectly. If the prompt says "respond with `{…}`", they respond with `{…}`. The custom-JSON contract is *good enough* for big models. It also predates MCP, predates the substrate, and predates the discovery work — it was a Day 1 expedient that survived because nothing previously forced its replacement.

The T17 finding is what forces the replacement: the moment you point this agent at a local 26B or 7B model, the assumption fails.

## §2 — What "OpenAI native function-calling" actually is

OpenAI's Chat Completions API has, since `gpt-3.5-turbo-0613` and formalized in 2024, a structured tool-calling sub-protocol. Three concrete differences from free-form content parsing:

### 2.1 — Request side: a `tools` array describes available functions

The client sends, alongside `messages`, a `tools` field:

```json
{
  "model": "gemma-4-26B-A4B-it-Q4_K_M.gguf",
  "messages": [...],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "crypto.sha256",
        "description": "Compute the SHA-256 digest of an input string.",
        "parameters": {
          "type": "object",
          "properties": {
            "data": {"type": "string", "description": "input to hash"},
            "encoding": {"type": "string", "enum": ["base16","base64"], "default": "base16"}
          },
          "required": ["data"]
        }
      }
    },
    ...
  ],
  "tool_choice": "auto"
}
```

Every callable function is enumerated with name + description + JSON-Schema-typed parameters. The model is told what's available, by the API, in a structured field — not by the user typing instructions in the system prompt.

### 2.2 — Response side: a structured `tool_calls` array, separate from content

When the model decides to call a tool, the assistant message's `tool_calls` field carries the structured call. `content` is either `null` or carries optional narration. The body looks like:

```json
{
  "choices": [{
    "message": {
      "role": "assistant",
      "content": null,
      "tool_calls": [{
        "id": "call_abc123",
        "type": "function",
        "function": {
          "name": "crypto.sha256",
          "arguments": "{\"data\":\"abc\"}"
        }
      }]
    },
    "finish_reason": "tool_calls"
  }]
}
```

Crucially, the model cannot wrap this in markdown. The framing is structurally separated from the content the model is free to format. **llama.cpp's `llama-server` enforces the schema by switching to grammar-constrained sampling** when `tools` is present — the model literally cannot emit anything other than a valid function-call shape during the relevant token positions. Hallucinated keys, malformed JSON, code fences around the call: structurally impossible.

### 2.3 — Continuation: results come back via `role: "tool"` messages keyed by `tool_call_id`

After dispatching the tool, the next request to the LLM appends:

```json
{
  "role": "tool",
  "tool_call_id": "call_abc123",
  "content": "<the tool's output, as text or JSON>"
}
```

`tool_call_id` ties the result to the originating call, allowing the model to issue multiple concurrent tool calls in one response and consume the results in any order. The current agent's `role: "function"` message has no such id and cannot support concurrent calls.

## §3 — Side-by-side

| Concern | Current (custom JSON) | Native function-calling |
| --- | --- | --- |
| **How the model knows what tools exist** | User has to mention them in the prompt, or the model has to guess. | Client sends a `tools` array on every request, derived from the registry. |
| **How tool-call shape is enforced** | Honor system. Parser fails on markdown, prose, or extra commentary. | Grammar-constrained sampling (in `llama-server`). Tool-call shape is structurally guaranteed. |
| **What goes wrong with small models** | They wrap calls in code fences, emit prose around the JSON, hallucinate keys. Parser silently fails. | The model literally can't deviate from the function schema during a tool call. |
| **Multiple tool calls per turn** | Impossible — the parser expects a single object as the entire `content`. | Native — `tool_calls` is an array. Each gets a unique `tool_call_id`. |
| **Concurrent calls + interleaved results** | Impossible. | Native via `tool_call_id` correlation. |
| **What's in `content` when a tool is called** | The JSON of the call. Nothing else. | `null` (or optional narration). The structured call lives in a separate field. |
| **Tool-result feedback to the model** | `role: "function"` with JSON-encoded payload — pre-2024 OpenAI dialect. | `role: "tool"` with `tool_call_id`. Current OpenAI dialect. |
| **Where the offered toolset lives** | Implicit in prompt + parser code. Not derivable from the registry. | Generated per turn from the registry filtered by the agent's policy — the loadout. |
| **What changes when a new tool is added** | A prompt-engineering update + parser test. Sometimes neither. | One line in `Tools.Builtins`; the catalog regenerates next turn. |
| **What changes when an ad's affordance is updated** | Re-document the prompt. | Re-emit the ad. The next request's `tools` array reflects the change. |
| **Verifiability against the spec** | Free-form. The model can claim to call `crypto.sha256` and the parser will believe it without checking the substrate. | The function-name in the response MUST be one the client offered. Mismatch is a parse error. |

## §4 — Why this is the load-bearing change for "Claude-effectiveness with local llamas"

The capability gap between gemma-26B and Sonnet is real but smaller than people assume *when the small model isn't asked to do work the big model gets for free*. Free-form-JSON tool-calling is exactly that work — it requires the model to:

1. Decide when to call a tool (the model is good at this).
2. Pick the right tool (good at this, given a catalog).
3. Construct the JSON shape exactly (variable — big models do it; small models drift).
4. Emit the JSON as the entire response without framing (unreliable; small models tend to chat).
5. Hold the schema and the conversational context simultaneously (cognitive cost).

Native function-calling eliminates steps 3, 4, 5 entirely. The model only has to do 1 and 2. Steps 3–5 are pushed down into the inference engine, where grammar-constrained sampling and the API protocol enforce them mechanically.

This is **not** a marginal optimisation. It changes which models are usable for agentic work. Gemma-26B can absolutely decide "I should call crypto.sha256 with data=abc"; it cannot reliably emit the result as raw JSON when its training pulls it toward chat. With native function-calling, the substrate makes the cognitive ask fit what the model can deliver.

The substrate built in 2026-05-18 already has every piece needed to generate the `tools` array dynamically:

- `Tools.Discovery.find_all/1` enumerates registered ads.
- Each `%ToolAd{}.operational.actions` is a per-action map.
- Each action has at least name and (currently empty) `inputs` schema.
- `affordance.declared` has the intent hints — these become the `function.description`.
- `constraint.idempotency` and `constraint.blast_radius` can drive `tool_choice` strategy.

The loadout (the substrate spec's §7.6-step-9 catalog regeneration, now made concrete) becomes a function of `(registry, policy)`, not a hardcoded blob.

## §5 — Persona, policy, and the loadout

Before listing deltas, one structural correction the first draft of this spec missed. Separating the catalog from the system prompt forces an explicit chain that has been implicit until now:

```text
role  ─────►  persona prompt        (who the agent is — narrative)
role  ─────►  %Policy{}             (what the agent is allowed to do — structural)
%Policy{} + Tools.Discovery ─────►  loadout (the tools offered TO the agent this turn)
loadout  ─────►  request.tools[]    (the structured offer the model sees)
model emits tool_calls
Tool.Dispatcher.<kind>/4 + same %Policy{} re-checks ─────► dispatch
```

Three observations follow:

**Policy gates both the offer and the dispatch.** Today `Tool.Dispatcher` consults `%Policy{}` only at dispatch time — the trust choke point that catches a misbehaving model. With native function-calling, the same policy must also gate the *offer*: the `tools[]` array we put in the request body. Otherwise we'd describe tools to the model the agent can't actually invoke, wasting context tokens and confusing the small model that just got told it could do something it can't. The offer-time check is for clarity; the dispatch-time check is for safety. Both run; neither is sufficient alone.

**Persona is just persona.** The `RolePrompt` table becomes responsible for *narrative* only — voice, register, domain framing. It stops carrying any list of tool names, formats, or examples. The role does still pick the policy (`:default` → permissive policy; `:sysadmin` → policy that allows system tools; future `:researcher` → only `resource.*` + `function.http`). The role-to-policy mapping is one explicit table; the persona-to-prompt mapping is a separate explicit table. Roles compose: a `:sysadmin` persona with a `:sandboxed` policy override is a coherent thing to ask for.

**The substrate registry is the affordance space; the loadout is the equipped subset.** `Tools.Discovery` carries every ad — native modules, mDNS-discovered llama-servers, MCP-imported tools, future trained ads — without prejudice about their binding kind. The loadout is what *this* agent in *this* engagement carries from that space, determined by the agent's policy at loadout-generation time. This is the same affordance-vs-actor distinction the broader vision rests on: the world affords X, but only some subset of X is meaningful or legible to a given actor in a given situation. The loadout is that subset, made concrete.

## §6 — Architectural style: behaviours, protocols, Comn alignment

Three style commitments inform the deltas in §7. Each one is a course-correction relative to the first draft of this spec, not a re-invention.

### 6.1 — Schemas are a behaviour callback, not data in the ad

The first draft put schemas as inline `inputs:` maps inside each tool's `ad/0`. That puts 12 dialects in 12 places with no enforcement and no shared vocabulary. The correction: **every kind behaviour gains an `input_schema/1` callback alongside the dispatch callback**. The compiler enforces presence — you cannot ship a tool that implements `:compute` without telling the substrate what shape each compute action expects. Schemas live next to the implementation they describe; the substrate knows where to find them without convention or registry.

```elixir
defmodule LLMAgent.Tool.Kinds.Compute do
  @callback compute(action :: String.t(), args :: map()) :: ...
  @callback input_schema(action :: String.t()) :: schema()
end
```

Shared vocabulary lives in a small `LLMAgent.Tool.Contracts` helper module — `Contracts.path()`, `Contracts.host()`, `Contracts.url()`, `Contracts.command()`, `Contracts.unary_data()` — returning JSON-Schema fragments tools compose. Cross-tool consistency comes from reuse, not from convention enforcement at review time.

This is the **behaviour-driven** answer rather than the **data-driven** one. It's how the Elixir ecology expresses "everything in this category must provide X."

### 6.2 — Protocols only where data-polymorphism buys us something

The current substrate uses behaviours for module-polymorphism (tool kinds, adapters, LLM clients). It doesn't use protocols. That's correct for the existing code — tool inputs are maps, processed by 12 modules; that's behaviour-shape, not protocol-shape. We don't add protocols just because they exist.

One place a protocol IS the right tool: **a `LLMAgent.LLMResponse` protocol** for "extract the tool calls from this response." Today different endpoints return different shapes — OpenAI returns `tool_calls`; a custom-JSON shim returns `content`-as-JSON; future Anthropic adapters would return their own shape; mock test clients return whatever they want. Protocol-dispatching on the response struct lets the agent loop be ignorant of which LLM emitted what; each `defimpl` knows how to read its own format. The agent loop doesn't switch on capability; the protocol does.

This is the minimum protocol footprint. We don't define `LLMAgent.ToolAdvertisable` or `LLMAgent.SchemaConvertible` — they'd be premature open-extension points for problems we don't have.

### 6.3 — Comn alignment

The substrate sits on Comn v0.4.0 but only uses a fraction of it. The migration sprint hardened that pattern by adding parallel infrastructure (`%LLMAgent.Tool.Policy{}`, Discovery's hand-rolled ETS table) instead of consuming Comn's existing abstractions. The function-calling work is a natural moment to course-correct, because the new modules being added (`Loadout`, refactored agent loop, `RolePolicy`) are greenfield code that should consume Comn idiomatically from day one.

Three specific alignments are in scope for phase 1:

- **`Comn.Error.to_error/1` for error coercion.** Comn defines a protocol that takes any error-like term and returns a canonical `%Comn.Errors.ErrorStruct{}`. New code uses the protocol; existing manual `ErrorStruct.new/3,4` calls in the legacy hot paths stay until subtraction.
- **`%LLMAgent.Tool.Policy{}` embeds `Comn.Contexts.PolicyStruct` identity.** Our policy keeps its concrete `allow`/`deny`/`require_approval`/`fidelity_min`/`provenance` matching logic; it gains the outer envelope (`name`, `description`, `metadata`) that Comn's PolicyStruct provides, so policies become first-class named things addressable across the Comn ecosystem. Our `RolePolicy.for/1` returns `%LLMAgent.Tool.Policy{}` carrying a `Comn.Contexts.PolicyStruct` identity for the role.
- **`Tools.Discovery` implements `Comn.Repo`.** Discovery's hand-rolled ETS becomes one Comn repo among many: `describe/get/set/delete/observe` callbacks delegate to its existing query and subscription semantics. The ETS layer underneath uses `Comn.Repo.Table.ETS.create/2` rather than raw `:ets.new`. Discovery's specific value-add (lease eviction, fidelity ranking, prefix-glob coordinate matching, tuple-space announcement consumption) stays — it's a repo with extra structure, not a replacement for what Comn provides.

Phase 2 (§8) covers the broader Comn folding that doesn't block this work.

### 6.4 — What's NOT changing

Two things look reachable from here but stay out:

- **No universal `Comn` behaviour with `look/recon/choices/act` callbacks.** That contract doesn't exist in Comn v0.4.0. The agento PRD's reference to it (VA4) is based on a stale 2026-02-15 analysis doc. Our `ad/0` is the substrate's introspection form and stays its own contract.
- **No `Comn.Schema` protocol or struct.** Comn has no schema primitive today. If we discover later that schema vocabulary should be reusable across the Comn ecosystem (not just llmagent's tools), proposing one upstream is its own project. For now, `LLMAgent.Tool.Contracts` is llmagent-owned.

## §7 — Phase 1 deltas

These are the changes, not an implementation plan. A separate plan turns each into ordered tasks with tests.

### 7.1 — `LLMClient` behaviour gains a `tools` opt

```elixir
@callback chat(messages :: [map()], opts :: map()) :: {:ok, content :: String.t() | nil, tool_calls :: [map()]} | {:error, term()}
```

The return shape changes from `{:ok, content}` to `{:ok, content, tool_calls}`. `content` may be `nil`. `tool_calls` is a list of OpenAI-format call records (`%{id, function: %{name, arguments}}`). Existing custom-JSON clients keep working by returning `{:ok, content, []}`.

`LLMClient.OpenAI.chat/2` accepts a `:tools` key in `opts` and passes it through to the request body. When present and non-empty, the response is parsed for `tool_calls`; when absent, behaviour is identical to today.

### 7.2 — A new `LLMAgent.Loadout` module derives the offer from the registry + policy

```elixir
LLMAgent.Loadout.for(%Policy{}) :: [openai_tool_descriptor]
```

The loadout module is the offer-time policy enforcement point. It:

1. Walks `Tools.Discovery` and collects every ad — regardless of binding kind. A native `:module`-bound ad, an mDNS `:openai_chat`-bound llama-server, and a future `:mcp`-bound imported tool all flow through the same path. The binding kind is the dispatcher's concern, not the loadout's.
2. Filters the ad list through `%Policy{}` — the same struct the dispatcher uses, the same `decide/4` rules — applied at offer time. Ads whose `(coordinate, kind, action)` triple isn't allowed by the policy are dropped before the model ever sees them.
3. Projects each surviving `(coordinate, kind, action)` triple into one OpenAI `tools[]` entry: function name from the coordinate-plus-action convention (`crypto.sha256`, `bash.exec`), description from `affordance.declared[].intent`, parameters from `operational.actions[name].inputs`.
4. Returns the array AND a lookup table from `function.name` back to `(coordinate, kind, action)` so the agent loop can route `tool_calls` to the dispatcher without re-resolving.

`Loadout.for/1` is pure — no side effects, deterministic in `(registry snapshot, policy)`. It can be cached per-policy and invalidated on discovery events. This is §7.6-step-9 of the substrate spec, made concrete.

### 7.3 — MCP-imported tools become first-class ads

The current MCP client (`lib/llmagent/mcp/`) predates the substrate and registers imported tools in the legacy `LLMAgent.Tools` persistent_term registry, not as `%ToolAd{}` records. This is the integration debt that the first draft of this spec wanted to punt and shouldn't.

`LLMAgent.MCP.Connection`'s tool-discovery step (the `tools/list` MCP request) emits one `%ToolAd{}` per discovered tool, registered in `Tools.Discovery` with binding `{:mcp, {server_ref, tool_name}}`. Each MCP tool's JSON-schema parameters land in `operational.actions[name].inputs` directly — MCP and OpenAI function-calling both use JSON-Schema, so the conversion is structural. The `:mcp` binding adapter (already declared in `Tool.Bindings`) routes dispatcher calls through the existing connection.

Once MCP tools are ads, the loadout walks one registry and the model gets a unified `tools[]` array containing native + MCP + (eventually) trained tools, all enforced by one policy. The legacy `LLMAgent.Tools.register/2` path for MCP stays alive during the transition under the §7.10-subtraction umbrella.

### 7.4 — Agent loop consumes `tool_calls` instead of parsing `content` as JSON

`LLMAgent.handle_info({ref, {:ok, content}})` becomes `handle_info({ref, {:ok, content, tool_calls}})`. For each entry in `tool_calls`, the function name is resolved via the Loadout lookup table to `(coordinate, kind, action)`, dispatched through `Tool.Dispatcher` with the agent's policy, and its result is fed back as a `role: "tool"` message with the matching `tool_call_id`. If `tool_calls == []`, behaviour matches today (assistant message, loop terminates unless parent-coordinated).

The legacy `parse_tool_call/1` stays as a fallback for one transition cycle: if `content` is JSON-decodable AND has `tool`/`action`/`args` AND `tool_calls` is empty, treat it as legacy. This handles models without native function-calling support during migration.

### 7.5 — Tool-result feedback uses `role: "tool"` + `tool_call_id`

`format_tool_result/1` emits `%{role: "tool", tool_call_id: id, content: <result>}` instead of `%{role: "function", content: <result>}`. The legacy `function` role stays accepted on the input side for older saved histories, but is no longer emitted.

### 7.6 — Persona prompts shrink; role-to-policy mapping becomes explicit

`RolePrompt.get/1` keeps the persona narrative and stops carrying any tool catalog, format examples, or invocation instructions. A new role-to-policy table — `LLMAgent.RolePolicy.for/1` or similar — maps `:default` / `:sysadmin` / future roles to the default `%Policy{}` for that role. The agent's `start_link/1` keeps accepting a `policy:` opt that overrides or narrows the role's default policy (per §6.3 of the substrate spec, narrowing only — agents cannot broaden beyond their role's default).

### 7.7 — Capability negotiation on the binding ad

Not every OpenAI-compatible endpoint supports the `tools` field (older llama.cpp builds, certain ollama versions, ad-hoc mocks). The binding ad's `meta` map carries a `capabilities` field — `%{capabilities: [:tools, :streaming]}` or similar — and the `LLMClient.OpenAI.chat/2` path checks it before sending `tools[]`. Endpoints that don't support `tools` fall back to the legacy custom-JSON path with the loadout serialised into the system prompt. This is the substrate paying off: the agent can route a model-aware call to a model that supports the feature.

### 7.8 — Kind behaviours gain `input_schema/1` callbacks

Each `LLMAgent.Tool.Kinds.<Kind>` module adds an `input_schema(action :: String.t()) :: schema()` callback alongside its dispatch callback. The compiler enforces that every tool implementing the kind also provides schemas for its actions. Schemas are JSON-Schema fragments (the format `tools[]` expects); they're keyed by action name.

Per-tool migration is mechanical: walk the existing `perform/2` clauses, derive the expected input keys, write a schema fragment per action that returns a `%{type: "object", properties: ..., required: [...]}`. The schemas land in the same module as the tool's `compute/2` / `query/2` / `act/3` callbacks. No central catalog file. The bulk of the work is the 12 tools' worth of schemas (~3–5 actions per tool, ~5 lines per action) — that's the visible cost. The structural cost is paid once in the behaviour module.

### 7.9 — `LLMAgent.Tool.Contracts` shared vocabulary

A small helper module returning JSON-Schema fragments for common input shapes:

```elixir
defmodule LLMAgent.Tool.Contracts do
  def path(opts \\ []), do: %{type: "string", description: opts[:description] || "Filesystem path"}
  def host(_opts \\ []), do: %{type: "string", description: "Hostname or IP address"}
  def url(_opts \\ []), do: %{type: "string", format: "uri"}
  def command(_opts \\ []), do: %{type: "string", description: "Shell command line"}
  def unary_data(_opts \\ []), do: %{type: "string", description: "Data to operate on"}
  # ... what else recurs as we write the 12 tools' schemas
end
```

Tools compose. The vocabulary grows organically as we discover what recurs. The compiler doesn't enforce reuse, but code review will — and the cost of writing `%{type: "string"}` inline isn't enough to fight over.

### 7.10 — New code uses `Comn.Error.to_error/1`

Inside Loadout, the refactored agent loop, the new MCP-as-ads adapter, and the role-to-policy lookup, errors flow through `Comn.Error.to_error/1` rather than direct `ErrorStruct.new/3,4`. The protocol coerces tuples, strings, atoms, and maps into the canonical struct. Existing legacy callsites stay as-is until subtraction.

### 7.11 — `%LLMAgent.Tool.Policy{}` embeds `Comn.Contexts.PolicyStruct` identity

The policy struct keeps its concrete matching fields (`allow`, `deny`, `require_approval`, `fidelity_min`, `provenance`) and gains an `identity: %Comn.Contexts.PolicyStruct{} | nil` field carrying the policy's name, description, and metadata. `Policy.from_legacy_or_struct/1` accepts the existing inputs and additionally accepts a `Comn.Contexts.PolicyStruct` directly (using its `metadata` to populate the matching fields if given). `RolePolicy.for/1` constructs policies with named identities — e.g., the `:sysadmin` role's policy carries `%PolicyStruct{name: "sysadmin"}`.

This is non-breaking: every existing call site of `Policy` keeps working. The identity field is opt-in for callers that want to name their policy.

### 7.12 — `Tools.Discovery` implements `Comn.Repo`

Discovery gains `Comn.Repo` callbacks: `describe/1` returns the registry's summary (count, indexes, capabilities); `get/2` looks up an ad by id or queries by coordinate; `set/2` registers or updates an ad; `delete/2` unregisters by id; `observe/2` returns a stream of registry events filtered by `%ToolQuery{}`. The existing `register/1`, `update/1`, `unregister/1`, `find_one/1`, `find_all/1`, `subscribe/2` API stays as the substrate-facing surface; the Comn.Repo callbacks are a thin alias layer over the same underlying state.

The internal ETS table uses `Comn.Repo.Table.ETS.create/2` for instantiation; subsequent reads stay direct (the hot path semantics don't change). Discovery remains its own GenServer because lease eviction and tuple-space announcement consumption are state-machine concerns Comn.Repo doesn't model — but its data lives in a Comn-style repo.

## §8 — Phase 2: deferred Comn folding

These are real and worth doing but don't block native function-calling. Each is a separate plan.

1. **`LLMAgent.Memory.ETS` → `Comn.Repo.Table.ETS`.** The memory backend is a textbook Comn repo — just keys and values keyed by agent. Replacing the homegrown ETS adapter with Comn's drops ~30 lines and removes a parallel codepath. Low risk; mechanical.
2. **Trained-ad commons + affordance graph on `Comn.Repo.Graphs.Graph`.** When the trained-ad lifecycle work starts (the deferred follow-on from the substrate spec), the affordance relationships, tool-dependency graphs, and trained-ad provenance chains are graph-shaped. Comn already has a libgraph-backed graph repo with `link`, `unlink`, `traverse`. Use it instead of rolling our own.
3. **EventBus + EventLog migration to `Comn.EventBus` + `Comn.EventLog`.** llmagent reimplemented both with identical APIs. ~80 lines deletable. Out of scope for function-calling because the migration touches event subscription points throughout the codebase.
4. **`Comn.Schema` upstream proposal.** If the `LLMAgent.Tool.Contracts` vocabulary stabilizes and we find ourselves wanting the same shapes in non-llmagent Comn consumers (other Elixir projects using Comn), promote it to a Comn.Schema protocol + canonical struct upstream. Triggered by demand, not speculation.
5. **`Comn.Cmd` / `Comn.Repo.Cmd.Shell` for the Bash tool.** Comn has a shell-command repo abstraction that maps cleanly onto what `LLMAgent.Tools.Bash` does today. Folding Bash onto it would let any Comn consumer execute shell commands through the same primitive. Defer because the boundary between "Bash as a tool" and "Bash as infrastructure" needs more thought.

Phase 2 is sequenced after the function-calling work lands AND has had time to expose any defaults that turn out wrong. Don't fold what you might want to unfold.

## §9 — What's deliberately out of scope here

Out of phase 1, out of phase 2, deferred indefinitely:

1. **Streaming tool calls.** OpenAI's streaming API emits `tool_calls` in delta chunks. Not needed for v1.
2. **Parallel tool dispatch.** The substrate can handle concurrent calls (Dispatcher is per-call). Wiring the agent loop to fan out `tool_calls.length > 1` simultaneously instead of serially is a follow-on.
3. **Loadout filtering by affordance match.** `affordance.declared` could be used to rank or omit tools per-prompt (e.g., "this looks like a network task, only expose `function.http` and `resource.network`"). That's affordance-discovery territory — the trained-ad lifecycle work.
4. **Cross-role policy composition.** A `:sysadmin` agent inside a `:sandboxed` envelope. Intersect/narrow exists in `Policy.intersect/2`; making it a first-class agent-start opt is a small follow-on.
5. **Per-tool output schemas.** `operational.actions[name].outputs` stays `%{}` in phase 1. Output shape is mostly the tool's concern, not the model's — the model gets the result as `role: "tool"` content and doesn't need a schema to consume it. We can declare outputs later if affordance reasoning needs them.

## §10 — Open questions

- **Function-name convention.** `"crypto.sha256"` (dot-separated coordinate+action) is the obvious choice. Some models may handle `"crypto_sha256"` better. Empirical question — try both with gemma-26B + mistral-7B.
- **`tool_choice` policy.** OpenAI accepts `"auto"`, `"none"`, `"required"`, or `{type: "function", function: {name: ...}}`. Default `"auto"` is right for v1; later the policy could promote `"required"` for jobs flagged as tool-mandatory.
- **Backwards compatibility window.** How long does the legacy custom-JSON path stay alive? Suggest: one minor version. Anything saved in DurableLog under the old shape gets a one-time migration on load.
- **Llama.cpp version requirements.** Grammar-constrained tool-calling needs `llama-server` from ~mid-2024. Skynet001/002 are running recent enough builds (per the TXT records seen by avahi). For older deployments, the legacy-JSON fallback is the answer; capability negotiation handles it.
- **Tests against the real LAN llamas.** T17 was hand-driven. A `@tag :integration` end-to-end test pointed at skynet001 (when reachable) would catch regressions in this path. Belongs in the implementation plan.
- **Loadout caching invalidation.** `Loadout.for/1` is pure but recomputing on every turn is wasteful. Cache key is `(policy, registry version)`. Discovery emits events on add/update/remove; the cache subscribes. Open question: do we want a per-agent cache or a process-global one?

## §11 — What this commits to

1. The model is told what tools exist via the structured `tools` field, not via prose in the system prompt.
2. The model emits tool calls in a structured response field that cannot be wrapped in chat formatting.
3. The agent loop reads `tool_calls`, not `content`-as-JSON. Legacy custom-JSON is a deprecation-bound fallback.
4. The loadout is derived from the substrate registry filtered by the agent's policy. Persona, policy, and loadout are three explicit concepts with three explicit tables.
5. Native, mDNS-discovered, MCP-imported, and (future) trained ads are all on the same conceptual footing in the registry. The loadout doesn't care about binding kind.
6. The substrate's binding ads carry capability flags; the agent chooses endpoints that support what it needs.
7. **Schemas live as behaviour callbacks**, not as inline data fields. The kind behaviour enforces presence; tools compose from a shared `LLMAgent.Tool.Contracts` vocabulary.
8. **One protocol added** — `LLMAgent.LLMResponse` — to dispatch tool-call extraction across endpoint shapes. No other protocols added; the substrate stays behaviour-driven.
9. **Comn alignment** for new code: `Comn.Error.to_error/1` for error coercion, `Comn.Contexts.PolicyStruct` identity embedded in policies, `Comn.Repo` callbacks on `Tools.Discovery`, `Comn.Repo.Table.ETS` for the underlying ETS layer. Existing code stays as-is until phase 2.

The structural improvement is moving the contract between agent and model **out of natural language and into protocol**, and making the persona/policy/loadout chain that connects role identity to equipped capability explicit. Schemas-as-behaviour-callbacks and Comn alignment are the architectural corrections that ride along because reopening the same code paths six months from now to fix the same drift would be wasteful. Everything downstream of this — multi-llama routing, the Bayesian-chain agent loop, the trained-ad commons — depends on small models being able to do tool-use reliably, and reliable tool-use depends on structural enforcement that the current free-form-JSON contract does not provide.

## Follow-on plan

To be written as `docs/superpowers/plans/<YYYY-MM-DD>-native-function-calling.md` after brainstorming this spec.

**Phase 1 tasks (this plan):**

1. `LLMAgent.Tool.Contracts` shared schema helper.
2. `input_schema/1` callbacks added to each kind behaviour (`Compute`, `Query`, `Action`, `Stream`, `Coordinate`, `SpawnKind`, `Generate`).
3. Per-tool schema fills — 12 tools' worth of action schemas using Contracts primitives.
4. MCP-tools-as-ads conversion in `LLMAgent.MCP.Connection`.
5. `%LLMAgent.Tool.Policy{}` embeds `Comn.Contexts.PolicyStruct` identity.
6. `LLMAgent.RolePolicy.for/1` table mapping roles → policies with named identities.
7. `LLMAgent.Loadout` module — walks Discovery, filters by Policy, projects to OpenAI `tools[]`.
8. `LLMClient` behaviour signature extension to return `tool_calls`.
9. `LLMClient.OpenAI.chat/2` accepts `:tools` opt, parses `tool_calls`.
10. `LLMAgent.LLMResponse` protocol for endpoint-agnostic tool-call extraction.
11. Agent loop refactor to consume `tool_calls`, dispatch via Loadout lookup table.
12. `role: "tool"` + `tool_call_id` continuation messages.
13. Capability negotiation on binding ads (`meta.capabilities`); legacy fallback path.
14. `Tools.Discovery` implements `Comn.Repo` callbacks; ETS layer via `Comn.Repo.Table.ETS`.
15. New code uses `Comn.Error.to_error/1` for error coercion.
16. Integration test against a LAN llama-server (skynet001 / skynet002 when reachable).

Legacy custom-JSON path stays alive throughout phase 1; subtraction is its own task at the end.

**Phase 2 tasks (separate plans, ordered by readiness):**

17. `LLMAgent.Memory.ETS` → `Comn.Repo.Table.ETS` migration.
18. EventBus + EventLog migration to Comn's equivalents.
19. Trained-ad commons + affordance graph on `Comn.Repo.Graphs.Graph` (gated on the trained-ad lifecycle spec).
20. `Comn.Schema` upstream proposal (gated on demand from non-llmagent Comn consumers).
21. Bash tool on `Comn.Repo.Cmd.Shell` (needs a separate decision about Bash-as-tool vs Bash-as-infrastructure).

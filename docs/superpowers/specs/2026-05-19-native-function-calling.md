# Native function-calling for local llama-servers

**Date:** 2026-05-19
**Status:** Draft
**Triggered by:** T17 end-to-end run against skynet001 (gemma-4-26B), 2026-05-18.

## Overview

The tool-substrate migration sweep (§7.2–§7.8 of `2026-05-03-tool-discovery-design.md`) shipped on 2026-05-18, putting every native tool behind a `%ToolAd{}` with kind-specific callbacks and routing the agent's dispatch path through `Tool.Dispatcher` with a structured `%Policy{}`. T17 verified the plumbing end-to-end against a real LAN llama (gemma-4-26B on skynet001 via mDNS-discovered ad). The plumbing worked. The model didn't.

What broke is the **tool-call serialisation contract between the LLM and the agent loop**. The current contract is informal: the agent expects the model to emit a single JSON object as the entire content of an assistant message, with keys `"tool"`, `"action"`, `"args"`. Gemma-26B emitted the same JSON but wrapped in a markdown code fence — the parser saw ``` ` ` ` ` ` ` ```json {…} ``` ` ` ` ``` instead of `{…}`, declared `is_tool_call: false`, and the loop terminated without dispatching anything. No telemetry fired. No tool ran.

This is the structural gap between "we have a substrate that knows what tools exist" and "the model actually uses it." The OpenAI Chat Completions API defines a native function-calling mechanism that closes this gap for any conforming OpenAI-compatible endpoint, **including llama.cpp's `llama-server`**, which has supported it since mid-2024 with grammar-constrained decoding. We're not using it. This spec is the design for adopting it.

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
| **Where the catalog lives** | Implicit in prompt + parser code. Not derivable from the registry. | Generated from the registered ads on every request — the registry IS the catalog. |
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

The catalog regeneration ("§7.6 step 9" in the substrate spec) becomes a function of the registry, not a hardcoded blob.

## §5 — What this requires changing

These are the deltas, not an implementation plan. A separate plan turns each into ordered tasks with tests.

### 5.1 — `LLMClient` behaviour gains a `tools` opt

```elixir
@callback chat(messages :: [map()], opts :: map()) :: {:ok, content :: String.t() | nil, tool_calls :: [map()]} | {:error, term()}
```

The return shape changes from `{:ok, content}` to `{:ok, content, tool_calls}`. `content` may be `nil`. `tool_calls` is a list of OpenAI-format call records (`%{id, function: %{name, arguments}}`). Existing custom-JSON clients keep working by returning `{:ok, content, []}`.

`LLMClient.OpenAI.chat/2` accepts a `:tools` key in `opts` and passes it through to the request body. When present and non-empty, the response is parsed for `tool_calls`; when absent, behaviour is identical to today.

### 5.2 — A new module derives the `tools` array from the registry

```elixir
LLMAgent.ToolCatalog.for(allowed_tools_policy :: %Policy{}) :: [map()]
```

Walks `Tools.Discovery`, filters by the agent's policy, projects each ad into the OpenAI tool-schema shape. One function-entry per `(coordinate, action)` pair the agent is allowed to call. Function names use the substrate's coordinate-plus-action convention — e.g., `crypto.sha256`, `bash.exec`, `file.read` — with a stable mapping back to `(coordinate, kind, action)` for dispatch.

This is §7.6-step-9 of the substrate spec, made concrete.

### 5.3 — Agent loop consumes `tool_calls` instead of parsing `content` as JSON

`LLMAgent.handle_info({ref, {:ok, content}})` becomes `handle_info({ref, {:ok, content, tool_calls}})`. If `tool_calls != []`, each one is resolved (function-name → (coordinate, kind, action) lookup), dispatched through `Tool.Dispatcher` with the existing policy, and its result is fed back as a `role: "tool"` message with the matching `tool_call_id`. If `tool_calls == []`, behaviour matches today (assistant message, loop terminates unless parent-coordinated).

The legacy `parse_tool_call/1` stays as a fallback for one transition cycle: if `content` is JSON-decodable AND has `tool`/`action`/`args` AND `tool_calls` is empty, treat it as legacy. This handles models without native function-calling support during migration.

### 5.4 — Tool-result feedback uses `role: "tool"` + `tool_call_id`

`format_tool_result/1` emits `%{role: "tool", tool_call_id: id, content: <result>}` instead of `%{role: "function", content: <result>}`. The legacy `function` role stays accepted on the input side for older saved histories, but is no longer emitted.

### 5.5 — System prompt is no longer the catalog

`RolePrompt.get/1` keeps the role-specific narrative ("You are a helpful assistant" / "You are a Linux systems administrator") but no longer needs to enumerate tools, formats, or examples. The tools field carries that information structurally.

### 5.6 — The legacy adapter for non-conforming endpoints

Not every OpenAI-compatible endpoint supports `tools` (older llama.cpp builds, certain ollama versions, ad-hoc mocks). The `LLMClient` behaviour gains a capability negotiation: the binding ad declares whether it supports native function-calling, and `ToolCatalog.for/1` is bypassed for endpoints that don't. This is also where the discovery substrate pays off — the binding ad can carry `{:capability, :tools}` and the agent picks an endpoint that supports the feature, falling back to the legacy-JSON path otherwise.

## §6 — What's deliberately out of scope here

These are real but separable:

1. **Per-tool action schemas.** Right now every `operational.actions[name].inputs` is `%{}` (empty). The catalog needs real schemas to be useful. Filling them in is a per-tool sweep — its own plan.
2. **Streaming tool calls.** OpenAI's streaming API emits `tool_calls` in delta chunks. Not needed for v1.
3. **Parallel tool dispatch.** The substrate can handle concurrent calls (Dispatcher is per-call). Wiring the agent loop to fan out `tool_calls.length > 1` simultaneously instead of serially is a follow-on.
4. **Catalog filtering by affordance.** `affordance.declared` could be used to rank or omit tools per-prompt (e.g., "this looks like a network task, only expose `function.http` and `resource.network`"). That's affordance-discovery territory — the trained-ad lifecycle work.
5. **MCP-imported tools.** The current MCP client predates the substrate. Folding MCP tools into the same catalog is a separate (smaller) integration.

## §7 — Open questions

- **Function-name convention.** `"crypto.sha256"` (dot-separated coordinate+action) is the obvious choice. Some models may handle `"crypto_sha256"` better. Empirical question — try both with gemma-26B + mistral-7B.
- **`tool_choice` policy.** OpenAI accepts `"auto"`, `"none"`, `"required"`, or `{type: "function", function: {name: ...}}`. Default `"auto"` is right for v1; later the policy could promote `"required"` for jobs flagged as tool-mandatory.
- **Backwards compatibility window.** How long does the legacy custom-JSON path stay alive? Suggest: one minor version. Anything saved in DurableLog under the old shape gets a one-time migration on load.
- **Llama.cpp version requirements.** Grammar-constrained tool-calling needs `llama-server` from ~mid-2024. Skynet001/002 are running recent enough builds (per the TXT records seen by avahi). For older deployments, the legacy-JSON fallback is the answer; capability negotiation handles it.
- **Tests against the real LAN llamas.** T17 was hand-driven. A `@tag :integration` end-to-end test pointed at skynet001 (when reachable) would catch regressions in this path. Belongs in the implementation plan.

## §8 — What this commits to

1. The model is told what tools exist via the structured `tools` field, not via prose in the system prompt.
2. The model emits tool calls in a structured response field that cannot be wrapped in chat formatting.
3. The agent loop reads `tool_calls`, not `content`-as-JSON. Legacy custom-JSON is a deprecation-bound fallback.
4. The catalog is derived from the substrate registry, not hand-maintained.
5. The substrate's binding ads carry capability flags; the agent chooses endpoints that support what it needs.

The structural improvement is moving the contract between agent and model **out of natural language and into protocol**. Everything downstream of this — multi-llama routing, the Bayesian-chain agent loop, the trained-ad commons — depends on small models being able to do tool-use reliably, and reliable tool-use depends on structural enforcement that the current free-form-JSON contract does not provide.

## Follow-on plan

To be written as `docs/superpowers/plans/<YYYY-MM-DD>-native-function-calling.md` after brainstorming this spec. Tasks will sequence: (a) per-tool action schemas, (b) `ToolCatalog` module + tests, (c) `LLMClient` behaviour extension + OpenAI adapter, (d) agent loop refactor to consume `tool_calls`, (e) `role: "tool"` continuation messages, (f) capability negotiation on the binding ad, (g) integration test against a LAN llama-server. Legacy custom-JSON path stays alive throughout; subtraction is its own task at the end.

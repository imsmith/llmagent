# Private LLM hub — gateway through the substrate

**Date:** 2026-10-02
**Status:** Draft for review
**Repos:** `llmagent` (substrate half), `agento` (hub half), `anemos` (policy plane, consumed as a dependency)

## Intent

One always-on local service that coding clients point at instead of a vendor,
and that fronts the private LLMs on this network. Daily use means: Claude Code,
pi, and OpenCode (and T3 Code, which drives those CLIs) work against the hub
with no per-session setup.

A client request is a job: *generate, against some `compute.llm.chat`
performer*. The hub schedules that job onto a performer. The vendor wire
protocols are compatibility shims at both edges; one canonical turn sits in the
middle, and every turn flows through `LLMAgent.Tool.Dispatcher.generate` under
a `%Policy{}`.

This is sub-project 1 of three. Sub-project 2 (tool hub: substrate tools and
`command.local.*` exposed to clients as an MCP server) and sub-project 3 (smart
hub: server-side folding, stored actions, server-run tools) get their own specs.

## Verified facts this design rests on

Checked on 2026-10-02 by running them, not by reading.

- `skynet001` (`10.10.1.226:8080`, `gemma-4-26B-A4B-it-Q4_K_M.gguf`, `n_ctx`
  262144, 4 slots) and `skynet002` (`10.10.1.229:8080`,
  `mistral-7b-instruct-v0.2.Q8_0.gguf`, `n_ctx` 32768, 4 slots) are both
  advertised over mDNS as `_llama._tcp` with `api=openai-compatible`.
- `priv/discovery/avahi-llama.tcl` turns those into ads with coordinate
  `compute.llm.chat`, kinds `[:generate]`, binding
  `[:openai_chat {:api_host … :model …}]`, fidelity `:authoritative`,
  provenance source `mdns/_llama._tcp`.
- `skynet001` streams OpenAI Chat tool calls and reasoning
  (`delta.reasoning_content`, `delta.tool_calls[].function.arguments`
  fragments, a final usage chunk when `stream_options.include_usage` is set,
  then `data: [DONE]`). Recorded in `test/fixtures/wire/openai_tool_stream.sse`.
- `skynet001` also answers Anthropic Messages natively. Its stream is recorded
  in `test/fixtures/wire/anthropic_tool_stream.sse` and is the reference for
  what an Anthropic-format stream of the same turn looks like
  (`message_start`, `content_block_start/delta/stop` with `thinking_delta` and
  `input_json_delta`, `message_delta` carrying `stop_reason`, `message_stop`).
- `Dispatcher.dispatch/5` passes caller `opts` through to the adapter callback
  (it adds `:ad`). An `into:` opt therefore reaches the adapter with no
  dispatcher change.
- `LLMAgent.Tool.Adapter.OpenAIChat.generate/4` today delegates to
  `LLMClient.OpenAI.chat/2`, which returns only the first choice's content
  string: no streaming, no tool calls, no usage.
- `%Policy{}` has a `provenance: %{source: [...] | :any, signed: boolean}`
  constraint, enforced in `Policy.decide/4`.
- Anemos verbs receive `(args, context)` and return `{:ok, result}` or
  `{:error, reason}`; `Anemos.Runtime.dispatch/3` returns `{:ok, results}`.
- **Dependency conflict:** `llmagent` pins `comn` at `v0.4.0`; `anemos` pins
  `v0.5.2`. `agento` cannot depend on both until `llmagent` moves to `v0.5.2`.
  `comn` gained `exqlite` after `v0.4.0`.
- Claude Code needs `/v1/messages` (it appends the path itself to
  `ANTHROPIC_BASE_URL`), treats `/v1/messages/count_tokens` as optional, and
  reads `/v1/models` when `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1`.
- pi takes custom providers from `~/.pi/agent/models.json` with `api` of
  `openai-completions` or `anthropic-messages`. An upstream issue
  (pi-mono #3168) reports custom providers listing but hanging; its current
  status is unverified and is an acceptance risk, not a design input.

## Data flow

```text
client (Anthropic Messages or OpenAI Chat, SSE)
  -> agento ingress: authenticate, decode wire -> %LLMAgent.Turn{}
  -> Hub.Router: pick a ToolAd (Anemos rule, else static fallback)
  -> Dispatcher.generate(ad, "chat", %{turn: turn}, policy: p, into: fun)
       resolve -> Policy -> kind -> adapter -> telemetry   (pipeline unchanged)
  -> adapter: encode canonical -> performer's wire, stream the response,
              decode chunks -> canonical events -> fun
  -> ingress fun: encode canonical events -> client's wire, write to the socket
  -> turn log: one row per turn
```

A turn is a function call in the connection process. No per-request process,
no per-request atom. When the client disconnects, the `into` function returns
`:halt` and the adapter cancels the upstream request.

## Substrate half (`llmagent`)

### `LLMAgent.Turn`

The canonical request. Fields:

| Field | Meaning |
| --- | --- |
| `system` | List of text blocks |
| `messages` | List of `%{role, content}`; `role` is `:user` or `:assistant`; `content` is a list of blocks |
| `tools` | List of `%{name, description, input_schema}` |
| `tool_choice` | `:auto`, `:none`, `:required`, or `{:tool, name}` |
| `params` | `max_tokens`, `temperature`, `top_p`, `stop`; absent keys stay absent |
| `stream` | Whether the client asked for a stream |
| `model` | The model string the client asked for, verbatim |

Block types: `:text`, `:image`, `:tool_call` (`id`, `name`, `input`),
`:tool_result` (`tool_call_id`, `content`, `is_error`), `:reasoning`.

Every block carries an `extra` map holding protocol-specific fields the
canonical model has no word for (Anthropic `cache_control`, thinking
`signature`). The rule:

- Same protocol in and out: `extra` is re-emitted, so prompt caching and
  thinking signatures survive an Anthropic client talking to an Anthropic
  performer.
- Crossing protocols: `extra` is dropped. That is the only silent loss.
- A request feature with no canonical representation and no safe drop
  (Anthropic server-side tools, unknown block types) is refused with a 400
  naming the feature. Nothing is silently mistranslated.

### Canonical stream events

| Event | Payload |
| --- | --- |
| `:start` | performer model id, input usage if known |
| `:block_start` | index, block type; for `:tool_call`, `id` and `name` |
| `:text_delta` | index, text |
| `:reasoning_delta` | index, text |
| `:tool_args_delta` | index, JSON fragment |
| `:block_stop` | index |
| `:stop` | reason (`:end_turn`, `:tool_use`, `:max_tokens`, `:stop_sequence`), usage |
| `:error` | reason |

OpenAI Chat has no block boundaries; the OpenAI decoder synthesises
`:block_start` / `:block_stop` when the delta kind or tool-call index changes.

### Codecs

`LLMAgent.Codec.Anthropic` and `LLMAgent.Codec.OpenAI`. Pure functions, no
processes, no I/O. Each provides four directions:

- wire request to `%Turn{}` (ingress)
- `%Turn{}` to wire request (egress)
- wire stream chunks to canonical events (egress), as a reducer over bytes that
  tolerates an SSE frame split across chunks
- canonical events to wire stream chunks (ingress)

Plus the non-streaming response in both directions, built by folding the event
stream into a final message so there is one code path, not two.

### Streaming generate

No new kind, no new behaviour callback.

- `generate/4` gains a clause for `%{turn: %Turn{}}`. With `into: fun` in opts,
  `fun` is called with each canonical event and returns `:cont` or `:halt`.
- It returns `{:ok, final_message, provenance}` when the stream ends, where
  `final_message` is the folded assistant message and `provenance` carries
  model id, usage, stop reason, and latency.
- The existing `%{messages: …}` clause stays as it is; the current agent loop
  and agento's `Harness.Turn` keep working untouched.

### Adapters

- `Adapter.OpenAIChat`: the new clause above, plus an optional bearer
  credential for cloud OpenAI-compatible performers.
- `Adapter.AnthropicMessages`: new, registered as binding kind
  `:anthropic_messages`. For Anthropic's API as a performer.

### `comn` bump

Move `llmagent` from `comn v0.4.0` to `v0.5.2`. Done first, alone, with the
full suite run before anything else lands, because everything else in the hub
half depends on it.

## Hub half (`agento`)

### Routes

| Route | Behaviour |
| --- | --- |
| `POST /v1/messages` | Anthropic ingress |
| `POST /v1/chat/completions` | OpenAI Chat ingress |
| `GET /v1/models` | Models the caller's policy can reach, projected from live ads; Anthropic list shape when the request carries an `anthropic-version` header, OpenAI list shape otherwise |

These sit in their own pipeline next to the existing harness routes. The
native harness API and the LiveViews are not changed.

Errors are returned in the calling protocol's own error envelope with a
truthful status: 401 unknown token, 403 policy refusal, 404 no performer for
the requested model, 400 unrepresentable request, 502 performer failure, 504
performer timeout.

### Identity and authority

- A bearer token (`Authorization: Bearer` or `x-api-key`) maps to a client
  record in an edn file: name, and a `%Policy{}`.
- No match is a 401. There is no anonymous client.
- The listener binds loopback by default; the bind address is configuration.
- Local-only versus cloud-allowed is expressed with the existing provenance
  constraint: a local-only client's policy lists
  `provenance.source: ["mdns/_llama._tcp"]`.
- The client name is attached to every event and every turn-log row.

### Cloud performers

- Declared in the hub's edn config and registered as ads at boot: coordinate
  `compute.llm.chat`, kinds `[:generate]`, `lease: :permanent`, fidelity
  `:authoritative`, provenance source `hub.config`, binding
  `:anthropic_messages` or `:openai_chat`.
- The credential is named by environment variable in the config, never written
  in it. The unit supplies it. It is wrapped so it does not survive `inspect`
  or logging.
- `ponytail:` env-var credentials are a stopgap. They move behind the
  credentials broker when that exists.
- Cloud use through the hub bills against an API key. A Claude subscription
  login is not forwarded; that is a cost consequence, stated here so it is a
  choice.

### `Hub.Router`

Input: the requested model string, the client, and the candidate ads the
client's policy admits.

1. Dispatch `LLM_REQUEST` into a supervised `Anemos.Runtime` with that input as
   context. A `ROUTE` module registered by the hub provides the verb a rule
   uses to name its choice. The rule file is loaded at boot from the config
   directory.
2. If no rule names a performer, static fallback: an ad whose model id equals
   the requested model; otherwise the configured default performer.
3. If nothing matches, 404.

An Anemos failure (parse error, rule crash) falls through to the static
fallback and emits an error event. Routing policy cannot take the hub down.

This is where `claude-*` model ids are mapped, for example Claude Code's small
background model to `skynet002` and its main model to `skynet001`.

### Turn log

SQLite, via `exqlite`, in the hub's data directory, file mode `0600`.

- One row per turn: timestamp, client, wire protocol, requested model, chosen
  ad id, performer model, stop reason, input and output tokens, duration,
  error.
- Two body columns hold the request as received and the final assistant
  message as sent. These are the vendors' wire payloads stored verbatim, not a
  storage format this project chose.
- Rows older than a configured retention are pruned on a timer. Default 30
  days. Claude Code resends its whole context every turn, so this file grows
  by tens of megabytes on a busy day.
- The log will contain whatever the clients sent, including secrets pasted
  into prompts. It is local, owner-readable only, and never emitted on the
  event bus.

The event bus still gets one `hub.request` event per turn carrying the row's
metadata without the bodies, so the Events LiveView shows hub traffic.

### Service

A `mix release` run by a systemd user unit, started at login, restarted on
failure. Configuration is edn in `~/.config/agento/`: listener, clients,
cloud performers, default performer, retention. The Anemos rule file sits
beside it.

## Build order

Each step ends in something that runs.

1. `comn` bump in `llmagent`; full suite.
2. `Turn`, canonical events, `Codec.OpenAI`, streaming clause in
   `Adapter.OpenAIChat`. Exit: a script streams a tool-calling turn from
   `skynet001` through `Dispatcher.generate`.
3. `Codec.Anthropic`; agento `POST /v1/messages` and `GET /v1/models`; token
   identity; static routing; `hub.request` events; release and unit.
   **Exit: Claude Code and pi work daily against the hub.**
4. Turn log.
5. `POST /v1/chat/completions` ingress.
6. Cloud performers and `Adapter.AnthropicMessages`.
7. Anemos routing.

## Testing

- Codec tests run against fixtures recorded from the producer, never written
  by hand. The two in `test/fixtures/wire/` were recorded with `curl -N`
  against `skynet001`'s `/v1/chat/completions` and `/v1/messages`, same prompt,
  same single-tool loadout. The plan records the rest the same way: plain
  text, multiple tool calls, `max_tokens` truncation, non-streaming, and an
  upstream error.
- Every stream decoder is tested with the fixture delivered whole, delivered
  one byte at a time, and truncated mid-frame.
- Cross-codec property: decoding the OpenAI fixture and encoding it as
  Anthropic yields a stream that the Anthropic decoder reads back to the same
  canonical events.
- One Bypass-backed fake performer drives the whole path: ingress, policy,
  routing, adapter, re-encoding, turn log. Includes a client disconnect
  mid-stream and asserts the upstream request is cancelled.
- Policy tests: unknown token, local-only client refused a cloud performer,
  empty policy denies.
- Acceptance, against the running unit: `claude -p` and pi each complete a
  prompt that requires a tool call and a follow-up turn.

## Out of scope

- `/v1/messages/count_tokens` (optional for Claude Code).
- OpenAI Responses API, and therefore Codex.
- Exposing substrate tools to clients (sub-project 2).
- The hub reading or altering turns: folding, stored actions, server-run tools
  (sub-project 3).
- `LLMAgent.perform/2`. The streaming generate built here is its internals;
  the call-site is a later, small addition.
- Anemos for authority and automation. This spec uses it for routing only.
- Listening beyond loopback with TLS.

## Risks

- Claude Code offers roughly twenty tools and a very large system prompt. A
  26B gemma will be weak at that loadout. The hub cannot fix model quality.
- Four slots per server, and Claude Code issues background requests in
  parallel with the main one. Routing the small-model traffic to `skynet002`
  mitigates it; queueing is not designed here.
- `mistral-7b-instruct-v0.2` has a 32k context and may not have a usable
  tool-calling template. Whether it can serve even the background traffic is
  unverified.
- `agento` depends on `llmagent` by path (`../llmagent`), which breaks in a git
  worktree. The hub half is built in `~/github/agento` against
  `~/github/llmagent`, so the substrate half must be merged there first.
- Thinking blocks crossing protocols lose their signatures. The rule: when a
  turn crosses protocols, `:reasoning` blocks in prior assistant messages are
  dropped from the outgoing request rather than translated. A local performer
  does not need them. An Anthropic performer with extended thinking and tool
  use may refuse a history whose thinking blocks are missing; the hub returns
  that refusal to the client as it is. The hub holds no per-conversation state
  and does not try to pin a conversation to a protocol family.

# Private LLM Hub — Substrate Half Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `LLMAgent.Tool.Dispatcher.generate` carry a full, streaming, tool-calling turn to an OpenAI-compatible performer, and give it an Anthropic Messages codec for the client side, so the agento hub can be built on top.

**Architecture:** A canonical `%LLMAgent.Turn{}` and a small canonical event vocabulary sit between two pure codecs. `Codec.Anthropic` reads what clients send and writes what they expect; `Codec.OpenAI` writes what performers expect and reads what they stream. `Adapter.OpenAIChat` gains one streaming clause that ties the OpenAI codec to Req, reached through the unchanged dispatcher pipeline with an `into:` option.

**Tech Stack:** Elixir, Req (streaming via `into:`), Jason, Bypass for tests, `comn v0.5.2`.

**Spec:** `docs/superpowers/specs/2026-10-02-private-llm-hub-design.md`. This plan implements spec build steps 1 and 2, plus the Anthropic codec from step 3. The agento hub (routes, identity, routing, turn log, service, cloud, Anemos) is a separate plan, written after this one is merged.

## Why this plan carries no implementation code

Standing rule for this project: code in a plan gets transcribed unrun. So this
plan states behaviour, exact interfaces, and exact test cases, and points at
artifacts that were produced by running the real thing:

- `test/fixtures/wire/` — recorded on 2026-10-02 from the live llama-servers
  and from a real Claude Code client. Never edit these by hand.
- `scripts/req_stream_probe.exs` — the Req streaming behaviour this plan
  relies on, run and observed.

Every command in this plan was run. The implementer writes the tests and code;
the plan says what they must prove.

## Global Constraints

- All work is in `llmagent`, on the current branch. Do not touch `agento`.
- No new dependencies. `comn` moves to `v0.5.2`; `req` constraint becomes `~> 0.5`.
- New modules are pure where this plan says pure: no processes, no I/O, no `Application` env.
- Never call `String.to_atom/1` on anything that came off the wire. Map wire strings to a fixed set of atoms with explicit clauses.
- The existing `generate/4` clause for `%{messages: …}` and `LLMClient.OpenAI.chat/2` keep their behaviour; the current agent loop and agento's `Harness.Turn` depend on them.
- Run tests with output redirected to a file, never piped: `mix test <path> > /tmp/t.log 2>&1 < /dev/null`. Piping hangs on leaked port children.
- Baseline before this plan: 128 doctests, 461 tests, 0 failures. Every task ends at 0 failures.
- `mix compile --warnings-as-errors` stays clean for this project's own code.
- Follow the repo's BEAM style: `@moduledoc`, `@doc`, `@spec` on public functions; permissive callback types go through `@type` aliases.
- Git: ordinary commits only. No history rewriting, no force pushes, no `git stash`.

## Review Focus

Inputs the spec implies but would otherwise go untested. Each is pinned to a task below.

1. An SSE frame split across network chunks, including in the middle of a multi-byte character. Expected: identical events to the unsplit stream. (Task 3)
2. A performer that returns an error instead of a stream: a JSON error body with a non-200 status, as in `openai_error_500_template.json` and `openai_error_400.json`. Expected: an error result carrying status and message, and no attempt to parse it as SSE. (Task 6)
3. A stream that ends without a finish reason because the performer died. Expected: an `:error` event and an error result, never a clean stop. (Tasks 4 and 6)
4. Tool-call arguments that are not valid JSON when assembled. Expected: fragments pass through the stream untouched, the folded message keeps the raw text, nothing crashes. (Task 2)
5. The client going away mid-stream. Expected: the upstream request is cancelled promptly and the call returns. (Task 6)

## Shared interfaces

Every task uses these names. They are fixed here so tasks agree.

### `LLMAgent.Turn` (struct)

| Field | Type |
| --- | --- |
| `model` | `String.t() \| nil` |
| `system` | list of blocks |
| `messages` | list of `%{role: :user \| :assistant \| :system, content: [block], extra: map}` |
| `tools` | list of `%{name: String.t(), description: String.t() \| nil, input_schema: map, extra: map}` |
| `tool_choice` | `:auto \| :none \| :required \| {:tool, String.t()} \| nil` |
| `params` | map with any of `:max_tokens`, `:temperature`, `:top_p`, `:stop`; absent keys absent |
| `stream` | `boolean` |
| `extra` | map |

Blocks are maps with a `:type` and an `:extra` map:

| `:type` | Other keys |
| --- | --- |
| `:text` | `text` |
| `:image` | `media_type`, `data` (base64 string) |
| `:tool_call` | `id`, `name`, `input` (map, or `nil` if the JSON did not parse), `input_json` (raw string) |
| `:tool_result` | `tool_call_id`, `content` (list of blocks), `is_error` (boolean) |
| `:reasoning` | `text` |

### Canonical events

| Event | Shape |
| --- | --- |
| start | `{:start, %{model: String.t() \| nil}}` |
| block start | `{:block_start, index, :text \| :reasoning \| {:tool_call, id, name}}` |
| deltas | `{:text_delta, index, binary}`, `{:reasoning_delta, index, binary}`, `{:tool_args_delta, index, binary}` |
| block stop | `{:block_stop, index}` |
| stop | `{:stop, :end_turn \| :tool_use \| :max_tokens \| :stop_sequence, %{input_tokens: integer \| nil, output_tokens: integer \| nil}}` |
| error | `{:error, term}` |

`index` counts blocks from 0 in the order they open. A block is always stopped before the next one starts.

### Functions

| Function | Returns |
| --- | --- |
| `LLMAgent.Turn.Fold.new/0` | fold state |
| `LLMAgent.Turn.Fold.step(state, event)` | fold state |
| `LLMAgent.Turn.Fold.result(state)` | `{:ok, %{message: assistant_message, model: String.t() \| nil, stop_reason: atom, usage: map}}` or `{:error, term}` |
| `LLMAgent.Codec.SSE.new/0` | splitter state |
| `LLMAgent.Codec.SSE.feed(state, binary)` | `{[%{event: String.t() \| nil, data: String.t()}], state}` |
| `LLMAgent.Codec.OpenAI.encode_request(turn, model)` | map ready for `Jason.encode!/1` |
| `LLMAgent.Codec.OpenAI.stream_decoder/0` | decoder state |
| `LLMAgent.Codec.OpenAI.decode_stream(state, binary)` | `{[event], state}` |
| `LLMAgent.Codec.OpenAI.finish_stream(state)` | `[event]` (empty if the stream stopped cleanly, otherwise closes open blocks and ends with an `:error` event) |
| `LLMAgent.Codec.OpenAI.decode_response(map)` | `[event]` |
| `LLMAgent.Codec.Anthropic.decode_request(map)` | `{:ok, Turn.t()}` or `{:error, {:unsupported, String.t()}}` |
| `LLMAgent.Codec.Anthropic.stream_encoder(opts)` | encoder state; opts `:model` (echoed to the client), `:id` |
| `LLMAgent.Codec.Anthropic.encode_stream(state, event)` | `{iodata, state}` |
| `LLMAgent.Codec.Anthropic.encode_response(fold_result, opts)` | map |
| `LLMAgent.Codec.Anthropic.encode_error(status, message)` | map |

---

### Task 1: Move to `comn v0.5.2`

A trial on 2026-10-02 showed the bump compiles and then fails 214 tests from three API changes. This task makes the suite green again and changes nothing else.

**Files:**

- Modify: `mix.exs`, `mix.lock`
- Modify: `lib/llmagent/memory/ets.ex`, `lib/llmagent/events.ex`, `lib/utils/require_binary.ex`
- Modify: `README.md` (dependency listing)

**Interfaces:**

- Consumes: nothing.
- Produces: an unchanged public API. `LLMAgent.Memory.ETS.fetch/2` still returns `{:error, :not_found}`; `init/2` is still idempotent; `LLMAgent.Events.emit/4` still records a bare `%Comn.Events.EventStruct{}`.

Known changes in `comn` between the two tags, observed in the trial:

| Call | `v0.4.0` | `v0.5.2` |
| --- | --- | --- |
| `Comn.Events.EventStruct.new/4` | returns the struct | returns `{:ok, struct}` |
| `Comn.Repo.Table.get/2` on a missing key | `{:error, {:not_found, _}}` | `{:error, %Comn.Errors.ErrorStruct{code: "repo.table/not_found"}}` |
| `Comn.Repo.Table.create/1` on an existing table | previous shape | `{:error, %Comn.Errors.ErrorStruct{code: "repo.table/already_exists"}}` |

- [ ] **Step 1:** In `mix.exs` set the `comn` tag to `v0.5.2` and the `req` constraint to `~> 0.5`. Run `mix deps.get`.
- [ ] **Step 2:** Run the suite. Expect roughly 214 failures; the existing tests are the failing tests for this task. Do not write new ones first.
- [ ] **Step 3:** Fix the three call sites in the table above so each module's own return contract is unchanged. Match on the error `code`, not on message text.
- [ ] **Step 4:** Rerun. Read each remaining failure and fix it at the call site that changed shape. If a failure is not caused by a `comn` API change, stop and report it; do not edit tests to pass.
- [ ] **Step 5:** `mix deps.update req`, then rerun the suite and `mix run --no-start scripts/req_stream_probe.exs`. The probe must print a `full:` line with status 200, a `halt:` line, a `404:` line with a captured JSON body, and a `refused:` line with a transport error. If the newer Req fails either the suite or the probe, pin back to the last working version, and add an entry to `ISSUES.md` naming the advisory that `mix deps.get` reports against it.
- [ ] **Step 6:** Update the dependency block in `README.md`.
- [ ] **Step 7:** Suite at 128 doctests, 461 tests, 0 failures. Commit.

### Task 2: `Turn`, canonical events, and the fold

**Files:**

- Create: `lib/llmagent/turn.ex`, `lib/llmagent/turn/fold.ex`
- Test: `test/llmagent/turn/fold_test.exs`

**Interfaces:**

- Consumes: nothing.
- Produces: `%LLMAgent.Turn{}`, the block and event shapes, and `Turn.Fold.new/0`, `step/2`, `result/1` as in Shared interfaces.

`Turn` is a struct with types and no behaviour. `Fold` reduces a list of canonical events to the final assistant message. It is the single path by which non-streaming responses and provenance are produced.

Tests (events are written out literally in the test; they are this plan's own vocabulary, not a wire format):

- [ ] text only: start, one text block with two deltas, stop `:end_turn` gives one `:text` block with the deltas joined, the stop reason, and the usage.
- [ ] reasoning, then two tool calls: three blocks in index order; each `:tool_call` has its `id`, `name`, `input_json` equal to the joined fragments, and `input` equal to the decoded map.
- [ ] invalid JSON arguments (fragments joining to `{"city":`): the block has `input: nil` and `input_json` kept verbatim; `result/1` is still `{:ok, _}`.
- [ ] a tool call with no argument deltas at all: `input_json` is `""` and `input` is `%{}`.
- [ ] an `:error` event anywhere makes `result/1` return `{:error, reason}`.
- [ ] events ending without `:stop` make `result/1` return `{:error, :incomplete}`.

- [ ] Write the tests, watch them fail, implement, watch them pass, commit.

### Task 3: SSE frame splitter

**Files:**

- Create: `lib/llmagent/codec/sse.ex`
- Test: `test/llmagent/codec/sse_test.exs`

**Interfaces:**

- Consumes: nothing.
- Produces: `Codec.SSE.new/0` and `feed/2`.

Splits a byte stream into SSE frames. A frame ends at a blank line. `data:` lines within a frame are joined with a newline; an `event:` line sets `event`. Lines starting with `:` are comments. Accept both `\n` and `\r\n`. Bytes after the last complete frame stay in the state.

Tests, using the recorded files as input:

- [ ] `openai_tool_stream.sse` fed whole: every frame's `data` is either `[DONE]` or decodes as JSON; the frame count equals the number of lines in the file that start with `data: `.
- [ ] the same file fed one byte at a time yields exactly the same list of frames.
- [ ] `anthropic_tool_stream.sse` fed whole: every frame has a non-nil `event`, and it equals the `type` inside that frame's JSON.
- [ ] a file cut off in the middle of a frame yields the complete frames before the cut and no partial frame.
- [ ] a frame whose data contains a multi-byte character, split between its bytes across two `feed/2` calls, yields the character intact. Build the input by taking a real frame from the fixture and replacing the delta text through `Jason`, not by hand-writing a frame.
- [ ] `\r\n` line endings yield the same frames as `\n` (convert a fixture in the test).

- [ ] Write the tests, watch them fail, implement, watch them pass, commit.

### Task 4: `Codec.OpenAI` (performer side)

**Files:**

- Create: `lib/llmagent/codec/openai.ex`
- Test: `test/llmagent/codec/openai_test.exs`

**Interfaces:**

- Consumes: `Turn`, events, `Turn.Fold`, `Codec.SSE`.
- Produces: `encode_request/2`, `stream_decoder/0`, `decode_stream/2`, `finish_stream/1`, `decode_response/1`.

**Decoding.** What the recorded streams contain, and what each becomes:

| On the wire | Canonical |
| --- | --- |
| first chunk | `{:start, %{model: …}}` from the chunk's `model` |
| `delta.reasoning_content` | `:reasoning` block, `:reasoning_delta` |
| `delta.content` (non-empty string) | `:text` block, `:text_delta` |
| `delta.tool_calls[]` with `id` and `function.name` | new `{:tool_call, id, name}` block |
| `delta.tool_calls[].function.arguments` | `:tool_args_delta` on the block for that wire `index` |
| `finish_reason` `stop` / `tool_calls` / `length` | closes the open block; reason `:end_turn` / `:tool_use` / `:max_tokens` |
| chunk with `usage` and empty `choices` | supplies `prompt_tokens` and `completion_tokens` |
| `data: [DONE]` | emits `{:stop, reason, usage}` |

The `:stop` event is held until `[DONE]` because usage arrives after the finish reason. If the performer sent no usage chunk, both token counts are `nil`. A change of delta kind, or a new tool-call index, stops the open block before starting the next. Canonical indices are assigned in opening order and are not the wire's tool-call index.

Decoder tests, each folding the decoded events with `Turn.Fold` and asserting on the result:

- [ ] `openai_text_stream.sse`: blocks are reasoning then text; the text is exactly `hello there`; stop reason `:end_turn`; usage equals the `usage` object in the file's last data chunk (read it from the file in the test).
- [ ] `openai_tool_stream.sse`: reasoning then one tool call named `get_weather` with input `%{"city" => "Paris"}`; stop reason `:tool_use`.
- [ ] `openai_two_tools_stream.sse`: reasoning then two tool calls with distinct ids, inputs `Paris` then `Oslo`, canonical indices 1 and 2.
- [ ] `openai_max_tokens_stream.sse`: stop reason `:max_tokens`.
- [ ] each of the four fed one byte at a time gives the same event list as fed whole.
- [ ] event-order invariant over all four: every `:block_start` is followed by its `:block_stop` before any other `:block_start`, and every delta's index is the currently open block.
- [ ] `openai_tool_stream.sse` truncated to its first half, then `finish_stream/1`: open block is stopped and the last event is `{:error, :incomplete_stream}`; folding gives `{:error, _}`.
- [ ] `finish_stream/1` after a complete stream returns `[]`.
- [ ] `decode_response/1` on `openai_two_tools.json` folds to the same block types, names, and inputs as the two-tools stream, with usage from the file.

**Encoding.** `encode_request(turn, model)` rules:

- `model` is the performer's model id from the binding, not `turn.model`.
- `turn.system` becomes one leading `system` message, blocks joined by a blank line. Omitted if empty.
- A `:system` message later in the conversation becomes a `user` message.
- After conversion, adjacent messages of the same role are merged into one. A performer on this network returns HTTP 500 for a non-leading system message; see `openai_error_500_template.json`.
- An assistant `:tool_call` block becomes an entry in `tool_calls` with `arguments` as a JSON string (`input_json` if present, else the encoded `input`).
- A `:tool_result` block becomes a `tool` message with `tool_call_id`. Its text blocks are joined into `content`. Tool messages for a user turn come before any remaining user text from that turn.
- `:reasoning` blocks are dropped.
- `:image` blocks become `image_url` parts with a `data:` URL.
- `tools` become `function` tools; `input_schema` becomes `parameters`. All `extra` at every level is dropped.
- `tool_choice`: `:auto`, `:none`, `:required` map to the same strings; `{:tool, name}` maps to the function-selection object; `nil` omits the key.
- `params` keys pass through under the same names. `stream` passes through; when true, add `stream_options.include_usage: true`.

Encoder tests. Build turns by decoding the captured Claude Code requests with `Codec.Anthropic.decode_request/1` once Task 5 exists; until then use small literal `%Turn{}` values:

- [ ] the encoded map round-trips through `Jason.encode!/1`.
- [ ] exactly one `system` message, at position 0.
- [ ] a turn with a mid-conversation `:system` message produces no `system` role after position 0 and no two adjacent messages with the same role among `user` and `assistant`.
- [ ] a turn whose assistant message holds a tool call and whose next user message holds its result produces `assistant` with `tool_calls`, then `tool` with the matching `tool_call_id`.
- [ ] `stream: true` adds `stream_options`; `stream: false` does not.
- [ ] no key named `cache_control`, `signature`, or `defer_loading` appears anywhere in the output.

- [ ] Write the tests, watch them fail, implement, watch them pass, commit.

### Task 5: `Codec.Anthropic` (client side)

**Files:**

- Create: `lib/llmagent/codec/anthropic.ex`
- Test: `test/llmagent/codec/anthropic_test.exs`
- Modify: `test/llmagent/codec/openai_test.exs` (switch the encoder tests to real decoded turns)

**Interfaces:**

- Consumes: `Turn`, events, `Turn.Fold`, `Codec.SSE` (tests only), `Codec.OpenAI` (tests only).
- Produces: `decode_request/1`, `stream_encoder/1`, `encode_stream/2`, `encode_response/2`, `encode_error/2`.

**Decoding a request.**

- `system` may be a string or a list of text blocks. `messages[].content` may be a string or a list. Both normalise to block lists.
- Roles `user`, `assistant`, `system` map to atoms by explicit clauses. Any other role is `{:error, {:unsupported, "role: …"}}`.
- Block types `text`, `image`, `tool_use`, `tool_result`, `thinking` map to `:text`, `:image`, `:tool_call`, `:tool_result`, `:reasoning`. Any other block type is `{:error, {:unsupported, "content block type: …"}}`.
- `tool_result.content` may be a string or a list of blocks.
- A tool entry with a `type` key is `{:error, {:unsupported, "server tool: …"}}`.
- `tool_choice` types `auto`, `any`, `tool`, `none` map to `:auto`, `:required`, `{:tool, name}`, `:none`.
- `max_tokens`, `temperature`, `top_p`, `stop_sequences` go to `params` (`stop_sequences` as `:stop`).
- Every key not named above stays in the `extra` of the turn, message, tool, or block it was found on.

Decoder tests:

- [ ] `claude_code_request.json` decodes to `{:ok, turn}`: `turn.model` equals the file's `model`; `turn.stream` is true; the tool count equals the file's; `turn.extra` has exactly the file's top-level keys other than `model`, `system`, `messages`, `tools`, `tool_choice`, `stream`, `max_tokens`, `temperature`, `top_p`, `stop_sequences`; a system block that had `cache_control` in the file has it in its `extra`; every tool has `defer_loading` in `extra` where the file had it.
- [ ] `claude_code_followup_request.json` decodes to `{:ok, turn}` containing, in order, an assistant message with a `:reasoning` block and a `:tool_call` block (`input` equal to the file's), then a user message with a `:tool_result` whose `tool_call_id` matches and `is_error` is true; the `:system` messages are present, including the one whose content was a string.
- [ ] hostile: a block of type `server_tool_use` gives `{:error, {:unsupported, _}}`; a tool with `"type": "web_search_20250305"` gives the same; `messages` missing or not a list gives an error; a role of `tool` gives an error. Make these by altering a decoded copy of the fixture in the test.
- [ ] encoding either decoded turn with `Codec.OpenAI.encode_request/2` satisfies every Task 4 encoder assertion. Move those assertions onto these turns.

**Encoding a stream.** One canonical event in, zero or more SSE frames out, each `event: <type>\ndata: <json>\n\n`:

| Canonical | Frames |
| --- | --- |
| `:start` | `message_start` with `id`, `type: message`, `role: assistant`, empty `content`, the `:model` given to `stream_encoder/1`, and zeroed usage |
| `:block_start` `:text` / `:reasoning` / tool call | `content_block_start` with a `text`, `thinking`, or `tool_use` block (`id`, `name`, empty `input`) |
| `:text_delta` / `:reasoning_delta` / `:tool_args_delta` | `content_block_delta` with `text_delta`, `thinking_delta`, or `input_json_delta` |
| `:block_stop` | `content_block_stop` |
| `:stop` | `message_delta` with `stop_reason` (`end_turn`, `tool_use`, `max_tokens`, `stop_sequence`) and usage, then `message_stop` |
| `:error` | `error` frame with an `error` object |

`nil` token counts are written as 0. Note the recorded llama-server streams defer every `content_block_stop` to the end and add a `signature_delta`; that is that server's habit, not the protocol. This encoder stops each block before the next starts and emits no `signature_delta`.

Stream tests. The source of events is a real performer stream decoded by `Codec.OpenAI`; the reference for shape is the Anthropic stream recorded from the same server for the same prompt:

- [ ] for each pair (`openai_text_stream` / `anthropic_text_stream`, `openai_tool_stream` / `anthropic_tool_stream`, `openai_two_tools_stream` / `anthropic_two_tools_stream`): encode the decoded OpenAI events, split the output with `Codec.SSE`, and assert the ordered list of `content_block_start` block types equals the reference file's, and the `stop_reason` equals the reference file's.
- [ ] in each encoded stream: the first frame is `message_start`, the last two are `message_delta` and `message_stop`, every frame's `event` equals its JSON `type`, and block `index` values start at 0 and increase by one.
- [ ] content survives: joining `text_delta` values gives `hello there` for the text stream; joining `input_json_delta` values per block and decoding gives `Paris` and `Oslo` for the two-tools stream.
- [ ] `message_start.message.model` is the string passed to `stream_encoder/1`, not the performer's model id.
- [ ] an `:error` event produces an `error` frame and nothing after it.
- [ ] `encode_response/2` on the fold of the two-tools stream gives a map with `type: message`, two `tool_use` blocks whose `input` values are maps, `stop_reason: tool_use`, and integer usage.
- [ ] `encode_error/2` gives `%{"type" => "error", "error" => %{"type" => _, "message" => _}}`, with the error type chosen from the status (400 `invalid_request_error`, 401 `authentication_error`, 403 `permission_error`, 404 `not_found_error`, 429 `rate_limit_error`, anything else `api_error`).

- [ ] Write the tests, watch them fail, implement, watch them pass, commit.

### Task 6: Streaming clause in `Adapter.OpenAIChat`

**Files:**

- Modify: `lib/llmagent/tool/adapter/openai_chat.ex`
- Test: `test/llmagent/tool/adapter/openai_chat_stream_test.exs`

**Interfaces:**

- Consumes: `Codec.OpenAI`, `Turn.Fold`.
- Produces: a new clause, `generate(%{api_host: host, model: model}, "chat", %{turn: %Turn{}}, opts)`.

Behaviour:

- Posts `Codec.OpenAI.encode_request(turn, model)` to `"#{api_host}/chat/completions"`, the same path the existing clause uses. The mDNS ads carry `api_host` without a `/v1` suffix and the servers answer on that path.
- `opts[:into]` is an optional function of one canonical event returning `:cont` or `:halt`. Absent, events are only folded.
- `opts[:timeout]` is the receive timeout, default 120000 ms, as in the existing client.
- The turn is always sent upstream with streaming on, whatever `turn.stream` says; `turn.stream` is the client's concern and is the caller's to honour from the returned message.
- Returns `{:ok, message, provenance}` where `message` is the fold's assistant message and `provenance` has `model` (the performer's reported model), `stop_reason`, `usage`, and `latency_ms`.
- Returns `{:error, {:http_error, status, body}}` when the status is not 200. The body is collected, decoded as JSON when it is JSON, and never passed to the SSE decoder. `scripts/req_stream_probe.exs` shows that Req delivers error bodies through the same `into:` callback, so the callback must look at the status first.
- Returns `{:error, :halted}` when `into` returned `:halt`; the upstream request is cancelled.
- Returns `{:error, :incomplete_stream}` when the body ended without `[DONE]`, after passing the `:error` event to `into`.
- Returns `{:error, reason}` for a transport failure such as a refused connection.
- The existing `%{messages: …}` clause and the unknown-action clause are untouched, and their existing tests still pass.

Req facts this relies on, all observed with the probe script: `into:` takes `fn {:data, binary}, {req, resp} -> {:cont | :halt, {req, resp}} end`; state can be kept in the response's private map; returning `:halt` makes the call return promptly with `{:ok, resp}`; a refused connection returns `{:error, %Req.TransportError{}}`.

Tests, with Bypass serving the recorded files as the response body with content type `text/event-stream`:

- [ ] `openai_two_tools_stream.sse`: returns `{:ok, message, provenance}`; the message has two tool calls for `Paris` and `Oslo`; provenance has `stop_reason: :tool_use`, integer token counts, and a non-negative `latency_ms`; the events received by `into` equal `Codec.OpenAI` decoding the same file directly.
- [ ] the request Bypass received is JSON with `stream` true, `stream_options.include_usage` true, and `model` equal to the binding's model, not the turn's.
- [ ] no `into` option: same `{:ok, _, _}` result.
- [ ] Bypass answering 500 with the body of `openai_error_500_template.json`: `{:error, {:http_error, 500, body}}` with `body["error"]["message"]` present; `into` was never called.
- [ ] Bypass answering 400 with `openai_error_400.json`: the same shape with 400.
- [ ] Bypass serving the first half of `openai_tool_stream.sse`, then closing: `{:error, :incomplete_stream}`, and the last event `into` saw is an `:error`.
- [ ] `into` returning `:halt` on the first event, with Bypass sending a chunk, then sleeping, then sending more (`Plug.Conn.chunk/2`): returns `{:error, :halted}` in well under the sleep time.
- [ ] a host with nothing listening (`Bypass.down/1`): `{:error, _}`, no raise.

- [ ] Write the tests, watch them fail, implement, watch them pass, commit.

### Task 7: Through the dispatcher, and proof against a live performer

**Files:**

- Create: `test/llmagent/tool/generate_turn_dispatch_test.exs`
- Create: `scripts/hub_probe.exs`
- Modify: `README.md`, `ISSUES.md`

**Interfaces:**

- Consumes: everything above, `LLMAgent.Tool.Dispatcher.generate/4`, `LLMAgent.Tools.Discovery`, `LLMAgent.ToolAd`, `LLMAgent.Tool.Policy`.
- Produces: the call the agento plan will be written against: `Dispatcher.generate(ad, "chat", %{turn: turn}, policy: policy, into: fun)`.

Dispatch tests. Register an ad shaped exactly like the mDNS shim's (coordinate `compute.llm.chat`, kinds `[:generate]`, binding `{:openai_chat, %{api_host: bypass_url, model: "m"}}`, fidelity `:authoritative`, provenance source `mdns/_llama._tcp`); unregister it on exit:

- [ ] with `%Policy{allow: ["compute.llm.chat"], fidelity_min: :authoritative}` and Bypass serving `openai_tool_stream.sse`: `{:ok, message, provenance}`, and `into` received events.
- [ ] with the default `%Policy{}`: `{:error, :forbidden, :not_allowed}`, and Bypass received no request.
- [ ] with a policy whose `provenance` is `%{source: ["hub.config"], signed: false}`: `{:error, :forbidden, :provenance}`, and Bypass received no request. This is the mechanism the hub's cloud guard will rest on.
- [ ] the `[:llmagent, :tool, :generate]` telemetry event fires for the allowed call.
- [ ] registering a second ad with the same `id` and a different `model` in its binding leaves exactly one ad for that id, carrying the new model. The shim derives its ad id from host and port, so this is what a host changing its model looks like. If this fails, stop and report: the hub's "config names hosts, not models" rule depends on it.

Live probe. `scripts/hub_probe.exs` starts the application, waits for a `compute.llm.chat` ad to be discovered (or takes `--host URL --model ID` and builds the ad itself), decodes `test/fixtures/wire/claude_code_request.json` with `Codec.Anthropic`, dispatches it through `Dispatcher.generate` with an allowing policy, and writes the Anthropic-encoded stream to stdout. It exits non-zero on any error result.

- [ ] Run it: `mix run scripts/hub_probe.exs --host http://10.10.1.226:8080 --model probe > /tmp/hub_probe.sse 2> /tmp/hub_probe.err < /dev/null`. Expect exit 0, a first frame of `message_start`, and a last frame of `message_stop`. The fixture's text is scrubbed placeholders, so the reply's content is meaningless; the shape is the test.
- [ ] Record what happened in the commit message, including the performer's reported model and the token usage.

Documentation:

- [ ] `README.md`: a short section on turn-shaped generate (the `%{turn: …}` argument, `into:`, the return shape), the two codecs, and the updated test counts.
- [ ] `ISSUES.md`: add a partial-resolution note to "mDNS-discovered endpoints are write-only when `llmagent` runs standalone": a discovered `compute.llm.chat` ad is now dialable through `Dispatcher.generate` with a turn. The agent's own loop still uses `llm_client` and `api_host`; that part stays open.

- [ ] Full suite, 0 failures. Commit.

## After this plan

Merge to `main` in `~/github/llmagent`, because `agento` depends on it by path. Then write the hub plan against the interfaces as built: routes, token identity, static routing, turn log, release and unit, then OpenAI Chat ingress (which adds the two remaining `Codec.OpenAI` directions and needs a request captured from a real OpenAI-protocol client), cloud performers, and Anemos routing.

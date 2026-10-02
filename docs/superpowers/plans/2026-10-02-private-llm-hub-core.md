# Private LLM Hub — Hub Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A long-running agento service that Claude Code points at with `ANTHROPIC_BASE_URL`, serving the private llama hosts through the substrate, with every turn logged.

**Architecture:** agento gains an Anthropic Messages ingress (`POST /v1/messages`, `GET /v1/models`). A bearer token identifies a client and its `%Policy{}`; a static router picks a discovered `compute.llm.chat` ad; the turn runs through `LLMAgent.Tool.Dispatcher.generate` in a task whose events the connection process writes out as SSE. Each turn becomes one SQLite row and one `hub.request` event. llmagent's mDNS shim is fixed to renew the leases it issues, so performers stay registered.

**Tech Stack:** Elixir, Phoenix/Bandit, `LLMAgent` (path dependency), `exqlite`, `ex_edn`, Tcl for the shim and the install script, systemd user units.

**Spec:** `docs/superpowers/specs/2026-10-02-private-llm-hub-design.md` (in llmagent). This plan implements spec build steps 3 and 4. OpenAI Chat ingress, cloud performers, and Anemos routing are a later plan.

## Why this plan carries no implementation code

Standing rule for this project: code in a plan gets transcribed unrun. This plan states behaviour, exact interfaces, and exact test cases, and rests on things that were run on 2026-10-02:

- A throwaway gateway built from `LLMAgent.Codec.Anthropic` and `Dispatcher.generate` served a real Claude Code (`claude -p`). A plain prompt and a prompt requiring the Read tool both completed correctly against `skynet001`.
- `MIX_ENV=prod mix release` builds agento; the release starts, serves HTTP, and discovers both llama hosts.
- `exqlite` and `ex_edn` behave as described under Verified facts.
- `test/fixtures/discovery/avahi_llama_browse.txt` (llmagent) is real `avahi-browse -p -r -t _llama._tcp` output. `test/fixtures/wire/` (llmagent) holds recorded performer streams and captured Claude Code requests. Never edit fixtures by hand.

## Verified facts

- **Leases are never renewed.** `priv/discovery/avahi-llama.tcl` emits each ad once with a 60-second lease. `Tools.Discovery` sweeps expired leases every 30 seconds. A hub running longer than a minute has no performers. Observed: the spike lost its ads and crashed on its second prompt.
- **The first turn is slow.** Claude Code's real request is about 83 KB and 18,000 input tokens. `skynet001` took 107–109 seconds before the first byte; the follow-up turn took 4 seconds with the prompt cached. `Adapter.OpenAIChat`'s default receive timeout is 120 seconds, which is too close.
- **What Claude Code sends.** `POST /v1/messages?beta=true`, `stream: true`, `max_tokens: 128000`, model `claude-sonnet-5-5`, token in `Authorization: Bearer` (from `ANTHROPIC_AUTH_TOKEN`). It also sends `HEAD /api/hello` at startup and tolerates a 404. It runs a second, small request (no tools, about 4 KB) in parallel with the main one and abandons it when the main one finishes. It did not call `count_tokens` or `/v1/models`.
- **Claude Code accepts the encoder's stream as built:** zero `input_tokens` in `message_start`, no thinking signature, no pings during a 108-second wait.
- **Chunks must be written by the connection process.** Writing from another process did not work in the spike; the events must be sent to the process that owns the `conn`.
- **agento baseline:** 88 tests, 0 failures, against merged llmagent `main`, after `mix deps.get` (which changes `mix.lock`).
- **agento's endpoint parses JSON bodies** in `Plug.Parsers` before the router, so the raw request body is gone by the time a controller runs unless a body reader keeps it.
- **A prod release binds every interface** (`*:PORT`): `config/runtime.exs` sets `ip: {0,0,0,0,0,0,0,0}`. It needs `SECRET_KEY_BASE` and `PHX_SERVER=true`, and logs an error about a missing static manifest unless `mix assets.deploy` ran first.
- **`LLMAgent.DurableLog` writes `data/llmagent_events.dets` relative to the working directory.**
- **`EDN.decode!/1`** returns maps with atom keys (`:"default-host"` for `:default-host`) and `%EDN.Vector{}` for vectors, which is enumerable. It creates atoms for keywords it has not seen, so it is used only on the operator's config file, once at boot, never on request data.
- **`Exqlite.Sqlite3`**: `open/1`, `execute/2`, `prepare/2`, `bind/2`, `step/2` (`{:row, list}` or `:done`), `release/2`, `close/1` work as named; blobs bind as `{:blob, binary}`. A new database file is created mode 0644.
- **`Agento.EventBusBridge`** rebroadcasts a fixed seed list of topics plus topics it discovers in the event log.
- `pi` is not installed on this host. `claude` and `opencode` are.

## Global Constraints

- Two repositories, each on a branch named `private-llm-hub`: `~/github/llmagent` (Task 1 only) and `~/github/agento` (everything else). agento depends on llmagent by path, so it sees the llmagent branch as checked out. Do not use git worktrees for agento.
- Run tests with output redirected to a file, never piped: `mix test > /tmp/t.log 2>&1 < /dev/null`. agento test runs must not overlap each other (shared DETS).
- Baselines: llmagent 130 doctests and 544 tests; agento 88 tests. Every task ends at 0 failures in the repository it touched.
- No JSON or YAML for configuration or project-chosen storage. Configuration is edn. The turn log's two body columns hold vendor wire payloads verbatim; that is the one sanctioned exception, from the spec.
- Never `String.to_atom/1` on request data. Never decode request data with `EDN`.
- Cloud forwarding is not built here. Nothing in this plan may make a turn reachable by a performer whose provenance is not `mdns/_llama._tcp`. A client record carrying `:cloud true` is a configuration error in this build.
- The listener binds loopback unless the operator says otherwise.
- The existing harness API, LiveViews, and their tests are not changed, apart from what this plan names.
- Follow each repo's style: `@moduledoc`, `@doc`, `@spec` on public functions; `@enforce_keys` on structs; no process dictionary. In agento, finish with `mix precommit`.
- Git: ordinary commits only. No history rewriting, no force pushes, no `git stash`.
- Nothing outside the two repositories and `/tmp` is created, enabled, or started by a task. Installing the real service is the operator's command, documented in Task 8.

## Review Focus

1. The client goes away mid-stream. Expected: the performer request is cancelled, the turn is logged as aborted, no process is left behind. (Task 5)
2. The performer fails before sending anything: refused connection, HTTP 500 from a chat template. Expected: the client gets a 502 with an Anthropic error body, not an empty 200 stream. (Task 5)
3. No performer can serve the request: every ad expired, or the default host is absent. Expected: a 404 naming the model, in an Anthropic error body. (Tasks 3 and 5)
4. The configuration is wrong: unreadable by design (group or world readable), malformed edn, duplicate tokens, a client with `:cloud true`. Expected: agento refuses to start and says why. A missing file is not an error: the hub has no clients and every `/v1` request is a 401. (Task 2)
5. The turn log cannot be written: directory missing, disk full, database locked. Expected: the client's turn is unaffected and an error is logged. (Task 6)
6. A long silence before the first byte. Expected: a turn that takes three minutes to start still completes. (Task 5)

## Shared interfaces

| Function | Returns |
| --- | --- |
| `Agento.Hub.Config.load(path)` | `{:ok, %Agento.Hub.Config{}}` or `{:error, String.t()}` |
| `Agento.Hub.Config.get()` | the config loaded at boot |
| `Agento.Hub.Config.client_for_token(config, token)` | `{:ok, client}` or `:error` |
| `Agento.Hub.Router.route(requested_model, client, config)` | `{:ok, %LLMAgent.ToolAd{}}` or `{:error, :no_performer}` |
| `Agento.Hub.Router.models(client)` | list of `%{id: String.t(), ad_id: String.t()}` |
| `AgentoWeb.Hub.Turn.run(conn, turn, ad, client, config)` | `{conn, summary}` |
| `Agento.Hub.TurnLog.record(row)` | `:ok`, always |
| `Agento.Hub.TurnLog.recent(limit)` | list of row maps, newest first |
| `Agento.Hub.TurnLog.prune(now)` | `{:ok, deleted_count}` |

`%Agento.Hub.Config{}` fields: `clients` (list), `default_host` (string or nil), `retention_days` (positive integer), `performer_timeout_ms` (positive integer), `data_dir` (string).

A client is `%{name: String.t(), token: String.t(), policy: %LLMAgent.Tool.Policy{}}`.

A turn summary, which is also a turn-log row, is a map with: `at` (ISO 8601 UTC string), `client`, `wire` (`"anthropic"`), `requested_model`, `ad_id`, `performer_model`, `outcome` (`"ok"`, `"aborted"`, `"error"`), `stop_reason` (string or nil), `input_tokens`, `output_tokens` (integers or nil), `duration_ms`, `error` (string or nil), `request_body` (binary), `response_body` (binary or nil).

---

### Task 1: Renew mDNS leases (llmagent)

**Repository:** `~/github/llmagent`, branch `private-llm-hub`.

**Files:**

- Modify: `priv/discovery/avahi-llama.tcl`
- Create: `test/tcl/avahi_llama_test.tcl`
- Modify: `Makefile` (add the new Tcl test to `test-tcl`)
- Create: `test/llmagent/discovery/avahi_llama_shim_test.exs`
- Modify: `ISSUES.md` (file the defect and its resolution)
- Fixture, already present: `test/fixtures/discovery/avahi_llama_browse.txt`

**Interfaces:**

- Consumes: `LLMAgent.Discovery.PortAdapter`, which already falls back from `register` to `update` on a duplicate id.
- Produces: discovered `compute.llm.chat` ads that stay registered while their host is advertised.

Behaviour:

- The shim remembers, per avahi instance, everything it needs to emit that instance's register line again.
- On a timer it re-emits a register line for every remembered instance, with a fresh `produced_at` and a fresh 60-second lease. Interval: 20 seconds, overridable by environment variable `AVAHI_LLAMA_RENEW_MS`.
- A `-` line still emits an expire and forgets the instance. A later `=` line for the same instance replaces what is remembered, which is how a host changing its model is picked up.
- The browse command is overridable by environment variable `AVAHI_LLAMA_BROWSE_CMD`, so a test can feed recorded output.
- The driver (spawning the browse command, the event loop) moves behind the same `argv0` guard `priv/discovery/bin-watch.tcl` uses, so the file can be sourced for its procs.
- Exit-on-stdin-EOF and killing the browse child on shutdown keep working.

Tcl tests (`tcltest`, sourcing the shim, capturing what it writes to stdout; feed lines from the fixture file):

- [ ] the fixture's two `=` lines produce two register lines; each contains the host's ad id (`mdns:_llama._tcp:<hostname>:<port>`), `compute.llm.chat`, and the model from that line's TXT record. Read the expected hostname, port, and model out of the fixture line in the test.
- [ ] the fixture's `+` lines produce nothing.
- [ ] calling the renewal proc after the two `=` lines produces two more register lines with the same ad ids.
- [ ] a `-` line for one instance produces an expire line for its ad id; renewal afterwards produces one register line, for the other instance.
- [ ] a second `=` line for the same instance with a different `model=` TXT value (build it by substituting within the fixture line) makes renewal emit the new model and not the old.
- [ ] a line with fewer than six fields, and an `=` line whose `api` is not `openai-compatible`, produce nothing and are not remembered.

Elixir integration test, with a fake source (`AVAHI_LLAMA_BROWSE_CMD` set to a command that prints the fixture then sleeps, `AVAHI_LLAMA_RENEW_MS=200`), started through `PortAdapter` exactly as agento's `config/runtime.exs` configures it:

- [ ] both ads appear in `Tools.Discovery`.
- [ ] an ad's lease `expires_at` read at two moments 600 ms apart is later the second time.
- [ ] after `Tools.Discovery.sweep_now/0` both ads are still present.
- [ ] stopping the adapter leaves no `tclsh` or fake-source process behind (follow the existing leak test in `port_adapter_test.exs`).

Steps:

- [ ] Write the Tcl tests. Run `tclsh test/tcl/avahi_llama_test.tcl`; they fail because the shim cannot be sourced without starting its driver.
- [ ] Write the Elixir test; watch it fail on the lease not advancing.
- [ ] Change the shim. Both test files pass; `tclsh test/tcl/bin_watch_test.tcl` still passes.
- [ ] Run the shim for real for 90 seconds under `iex -S mix` or a short script and confirm both live ads are still registered. Record the observation in the commit message.
- [ ] File the defect in `ISSUES.md` with its resolution. Full suite. Commit.

### Task 2: Hub configuration (agento)

**Repository:** `~/github/agento`, branch `private-llm-hub`, for this and every later task.

**Files:**

- Modify: `mix.exs` (add `{:exqlite, "~> 0.27"}`, `{:ex_edn, path: "../ex_edn"}`, and `{:bypass, "~> 2.1", only: :test}`), `mix.lock`
- Create: `lib/agento/hub/config.ex`
- Modify: `lib/agento/application.ex` (load the config at boot; refuse to start on `{:error, _}`)
- Modify: `config/test.exs` (point the hub config path at a file the tests control)
- Test: `test/agento/hub/config_test.exs`
- Create: `priv/hub.example.edn`

**Interfaces:**

- Produces: `Config.load/1`, `Config.get/0`, `Config.client_for_token/2`, the `%Config{}` struct and client shape.

Behaviour:

- The path is the `AGENTO_HUB_CONFIG` environment variable, else `~/.config/agento/hub.edn`.
- File keys: `:clients` (vector of `{:name "…" :token "…"}`), `:default-host`, `:retention-days` (default 30), `:performer-timeout-seconds` (default 900), `:data-dir` (default `~/.local/share/agento`).
- A missing file loads as a config with no clients and the defaults. That is not an error.
- These are errors, each with a message naming the problem: malformed edn; the file readable or writable by group or others; a client without a name or with a token shorter than 16 characters; two clients with the same token or the same name; a client carrying `:cloud true`; a non-positive retention or timeout; an unknown top-level key.
- Every client's policy is `%Policy{allow: ["compute.llm.chat"], fidelity_min: :authoritative, provenance: %{source: ["mdns/_llama._tcp"], signed: false}}`. The provenance constraint is never `nil`.
- `client_for_token/2` compares with `Plug.Crypto.secure_compare/2` against every client, so timing does not reveal which client matched.
- The loaded config is held in `:persistent_term`. `Application.start/2` raises with the loader's message on `{:error, _}`.

Tests (write real files under a temp directory with `File.chmod!/2`):

- [ ] a valid file with two clients loads; both have the policy above; defaults apply to omitted keys.
- [ ] a missing file loads with `clients: []`.
- [ ] each error case above returns `{:error, message}` and the message mentions the offending thing (the client name, the key, the mode).
- [ ] a file with mode `0640` is refused; the same file with `0600` loads.
- [ ] `client_for_token/2` finds each client by its token and returns `:error` for an unknown token, an empty string, and a prefix of a real token.
- [ ] no client's policy admits an ad whose provenance source is `hub.config`: build such an ad and assert `Policy.decide/4` refuses it.
- [ ] `priv/hub.example.edn` loads (after `chmod 0600` on a copy) — the example cannot rot.

- [ ] Add the dependencies and run `mix deps.get`. Write the tests, watch them fail, implement, watch them pass. Full suite (the 88 existing tests plus these). Commit, including `mix.lock`.

### Task 3: Static router (agento)

**Files:**

- Create: `lib/agento/hub/router.ex`
- Test: `test/agento/hub/router_test.exs`

**Interfaces:**

- Consumes: `LLMAgent.Tools.Discovery.find_all/1`, `LLMAgent.Tool.Policy.decide/4`, a client, a config.
- Produces: `Router.route/3`, `Router.models/1`.

Behaviour:

- Candidates are the `compute.llm.chat` ads the client's policy admits for kind `:generate`, action `"chat"`.
- `route/3` returns, in order of preference: the candidate whose binding model equals the requested model; else the candidate on the configured default host; else `{:error, :no_performer}`.
- An ad is "on" a host when the host string equals the hostname part of the ad's `api_host`, or the hostname segment of an mDNS ad id (`mdns:_llama._tcp:<hostname>:<port>`).
- With no default host configured and no model match, the result is `{:error, :no_performer}`. The router never picks arbitrarily.
- `models/1` lists one entry per candidate: `id` is the binding's model, `ad_id` the ad's id.
- Nothing here names a model. Routing reads what ads advertise at the time of the call.

Tests (register ads directly in `Tools.Discovery`, shaped like the shim's; reset the registry in setup):

- [ ] requested model equal to an advertised model routes to that ad.
- [ ] an unknown model (`claude-sonnet-5-5`) routes to the default host's ad, matched by mDNS id hostname.
- [ ] the default host is matched by `api_host` hostname when the ad id is not an mDNS id.
- [ ] unknown model and no default host: `{:error, :no_performer}`.
- [ ] default host configured but its ad absent: `{:error, :no_performer}`.
- [ ] an ad with provenance `hub.config` is never returned and never listed, even when its model equals the requested model exactly.
- [ ] after `Discovery.update/1` replaces a host's ad with a new model, `models/1` lists the new model only and the old model name routes to the default host.
- [ ] an empty registry gives `{:error, :no_performer}` and `[]`.

- [ ] Write the tests, watch them fail, implement, watch them pass. Commit.

### Task 4: Identity plug and raw body (agento)

**Files:**

- Create: `lib/agento_web/hub/auth.ex`, `lib/agento_web/hub/raw_body.ex`
- Modify: `lib/agento_web/endpoint.ex` (`Plug.Parsers` gets `body_reader:` and a larger `length:`)
- Modify: `lib/agento_web/router.ex` (a `:hub` pipeline and a `/v1` scope with the two routes, pointing at a controller that Task 5 fills in)
- Create: `lib/agento_web/controllers/hub_controller.ex` (`models` action only in this task)
- Test: `test/agento_web/hub/auth_test.exs`, `test/agento_web/controllers/hub_models_test.exs`

**Interfaces:**

- Consumes: `Config.get/0`, `Config.client_for_token/2`, `Router.models/1`, `LLMAgent.Codec.Anthropic.encode_error/2`.
- Produces: `conn.assigns.hub_client` on authenticated `/v1` requests; `conn.private[:raw_body]` holding the request bytes for `/v1` requests; `GET /v1/models`.

Behaviour:

- The token is read from `Authorization: Bearer <token>`, else from `x-api-key`.
- No token or an unknown token: 401, JSON body from `Codec.Anthropic.encode_error/2`, and the request goes no further.
- The raw body is kept only for paths under `/v1/`, so the existing routes pay nothing. `Plug.Parsers` `length:` becomes 64 MB (a Claude Code request with images can exceed the 8 MB default).
- `GET /v1/models`: when the request carries an `anthropic-version` header, the Anthropic list shape (`data` entries with `type: "model"`, `id`, `display_name`, `created_at`; `has_more: false`; `first_id`; `last_id`); otherwise the OpenAI list shape (`object: "list"`, `data` entries with `id`, `object: "model"`, `owned_by`).
- The existing harness route-coverage test must keep passing. If it requires every live route to be documented, scope it to the harness routes rather than documenting `/v1` in the harness's OpenAPI document; say which in the commit message.

Tests:

- [ ] no token, a wrong token, and a token in the wrong header scheme (`Authorization: Basic …`) each get 401 with `%{"type" => "error", "error" => %{"type" => "authentication_error"}}`.
- [ ] a valid token in `Authorization: Bearer` and the same token in `x-api-key` both reach the action; `hub_client` is the right client.
- [ ] `GET /v1/models` with `anthropic-version` lists exactly the models `Router.models/1` returns, in the Anthropic shape; without the header, in the OpenAI shape; with an empty registry, an empty `data` list and a 200.
- [ ] a `POST` under `/v1/` has `conn.private[:raw_body]` byte-identical to what was sent, including insignificant whitespace; a `POST` to an existing harness route has no such key.
- [ ] malformed JSON to a `/v1/` path is a 400.
- [ ] the existing 88 tests pass.

- [ ] Write the tests, watch them fail, implement, watch them pass. Commit.

### Task 5: `POST /v1/messages` (agento)

**Files:**

- Create: `lib/agento_web/hub/turn.ex`
- Modify: `lib/agento_web/controllers/hub_controller.ex` (`messages` action)
- Test: `test/agento_web/controllers/hub_messages_test.exs`, `test/support/hub_case.ex` (shared setup: a config with one client, a Bypass performer, a registered ad shaped like the shim's)

**Interfaces:**

- Consumes: `LLMAgent.Codec.Anthropic` (`decode_request/1`, `stream_encoder/1`, `encode_stream/2`, `encode_response/2`, `encode_error/2`), `LLMAgent.Tool.Dispatcher.generate/4`, `LLMAgent.Turn.Fold`, `Router.route/3`, the fixtures in `../llmagent/test/fixtures/wire/`.
- Produces: `AgentoWeb.Hub.Turn.run/5` returning `{conn, summary}`; the `messages` action. Task 6 and Task 7 consume the summary.

Behaviour:

- Decode `conn.body_params` with `Codec.Anthropic.decode_request/1`. `{:error, {:unsupported, what}}` and `{:error, {:invalid, what}}` are a 400 whose message is `what`.
- Route with `Router.route/3` on the turn's model. `{:error, :no_performer}` is a 404 whose message names the requested model.
- Run `Dispatcher.generate(ad, "chat", %{turn: turn}, policy: client.policy, into: fun, timeout: config.performer_timeout_ms)` in a linked task. `fun` sends each event to the connection process and waits for its answer, `:cont` or `:halt`. This gives backpressure, lets a failed write halt the performer, and keeps every write in the process that owns the connection.
- The connection process starts the response when the first event arrives, not before. Until then nothing has been sent, so a failure can still be an ordinary error response.
- Streaming request (`turn.stream`): `text/event-stream`, each event encoded with `Codec.Anthropic.encode_stream/2` using the client's requested model. A failed write answers `:halt`.
- Non-streaming request: events are folded; the response is `Codec.Anthropic.encode_response/2` as JSON.
- Every response to an authenticated request that reached routing carries `x-hub-performer: <ad id>` and `x-hub-billing: local`.
- Failure before the first event: `{:error, :forbidden, _}` is 403; `{:error, {:http_error, status, body}}` is 502 with the performer's message when it has one; a timeout is 504; any other error is 502. All in Anthropic's error envelope.
- Failure after the stream started: the encoder's `error` frame, then the response ends.
- The summary's `outcome` is `"ok"` on a clean stop, `"aborted"` when the client went away, `"error"` otherwise. `response_body` is the JSON of `encode_response/2` for a turn that produced a final message, else nil.
- No conversation state is kept between requests.

Tests (performer is Bypass serving recorded llmagent fixtures; request bodies are the captured Claude Code requests):

- [ ] `claude_code_request.json` against `openai_tool_stream.sse`: 200, `text/event-stream`; the body parses as SSE frames beginning with `message_start` and ending `message_delta`, `message_stop`; it contains a `tool_use` block named `get_weather`; `message_start` reports the client's model, not the performer's; headers `x-hub-performer` and `x-hub-billing: local` are present.
- [ ] the performer received a request whose `model` is the ad's model and whose first message has role `system`.
- [ ] `claude_code_followup_request.json` against `openai_text_stream.sse`: 200, and the joined `text_delta` values are `hello there`.
- [ ] the same request with `"stream": false`: 200 `application/json`, `type: "message"`, a text block `hello there`, integer usage.
- [ ] a request with a `server_tool_use` block: 400 `invalid_request_error`, message names the block type; the performer was not contacted.
- [ ] no ad registered: 404 `not_found_error`, message contains the requested model; no performer contacted.
- [ ] performer answers 500 with `openai_error_500_template.json`: 502 `api_error` with the performer's message; content type is JSON, not an event stream.
- [ ] performer down (`Bypass.down/1`): 502.
- [ ] performer sends half of `openai_tool_stream.sse` then ends: 200 event stream whose last frame is `error`.
- [ ] a performer that sleeps before answering longer than a 200 ms `performer_timeout_ms` set for the test: 504.
- [ ] a performer that waits 1.5 seconds before its first byte, with the default timeout: 200 and a complete stream. This pins the slow-first-byte case.
- [ ] `Turn.run/5` returns a summary with `outcome: "ok"`, the token counts from the fixture's usage chunk, `ad_id`, `performer_model`, and `request_body` equal to the bytes sent.
- [ ] client disconnect: drive `Turn.run/5` with a performer that streams slowly (raw `:gen_tcp`, as in llmagent's `openai_chat_stream_test.exs`) from a process that is killed after the first event. Assert the performer's socket closes within a second and the task is gone. The summary for an aborted turn is covered in Task 6, where it is recorded.
- [ ] a turn for a client whose policy has no allow rules is 403 and the performer was not contacted.

- [ ] Write the tests, watch them fail, implement, watch them pass. Full suite. Commit.

### Task 6: Turn log (agento)

**Files:**

- Create: `lib/agento/hub/turn_log.ex`
- Modify: `lib/agento/application.ex` (supervise it), `lib/agento_web/controllers/hub_controller.ex` (record each summary)
- Test: `test/agento/hub/turn_log_test.exs`; extend `test/agento_web/controllers/hub_messages_test.exs`

**Interfaces:**

- Consumes: the summary from Task 5; `config.data_dir`, `config.retention_days`.
- Produces: `TurnLog.record/1`, `recent/1`, `prune/1`.

Behaviour:

- A GenServer owning one `Exqlite.Sqlite3` connection to `<data_dir>/hub_turns.sqlite`, WAL mode.
- It creates the directory (mode 0700) and the file (mode 0600) if absent, and sets the file to 0600 if it exists with a wider mode.
- One table, one row per turn, columns matching the summary's keys. `request_body` and `response_body` are blobs holding the wire payloads verbatim.
- `record/1` is a cast and returns `:ok` whatever happens. A write that fails is logged at error level and dropped. If the database cannot be opened at start, the process still starts, logs the reason, and drops every record; the hub keeps serving.
- `prune/1` deletes rows whose `at` is older than `retention_days` before the given time, and runs hourly on a timer.
- The controller records every turn that reached routing, including refused, failed, and aborted ones. An aborted turn is recorded when the connection process is still alive to do so; when it was killed, the linked task dies with it and nothing is recorded. State this in the moduledoc.

Tests (each test gets its own temp `data_dir`):

- [ ] a recorded summary comes back from `recent/1` with every field equal, including a `request_body` containing bytes that are not valid UTF-8.
- [ ] the file's mode is 0600 and the directory's is 0700; a pre-existing 0644 file is tightened.
- [ ] `prune/1` with rows at 40, 20, and 0 days old and 30-day retention deletes exactly the oldest.
- [ ] `recent/1` orders newest first and honours the limit.
- [ ] a `data_dir` that cannot be created (a path under a regular file): the process starts, `record/1` returns `:ok`, `recent/1` returns `[]`, and an error was logged (`ExUnit.CaptureLog`).
- [ ] through the controller: one successful turn produces one row with `outcome: "ok"`, the client name, the requested model, the performer's model, and both bodies; a 404 turn produces a row with `outcome: "error"` and no `ad_id`.
- [ ] through the controller with the log unable to open: the client still gets its 200 stream.

- [ ] Write the tests, watch them fail, implement, watch them pass. Full suite. Commit.

### Task 7: `hub.request` events (agento)

**Files:**

- Modify: `lib/agento_web/controllers/hub_controller.ex`, `lib/agento/event_bus_bridge.ex` (add `hub.request` to the seed topics)
- Test: extend `test/agento_web/controllers/hub_messages_test.exs`

**Interfaces:**

- Consumes: the summary; `LLMAgent.Events.emit/4`; `LLMAgent.EventBus.subscribe/1`.
- Produces: one `hub.request` event per recorded turn.

Behaviour:

- After a turn, emit type `:request`, topic `hub.request`, with every summary field except `request_body` and `response_body`.
- The bodies never reach the event bus, the event log, or the durable log.

Tests:

- [ ] a successful turn emits one `hub.request` event whose data has the client, requested model, ad id, performer model, outcome, token counts and duration.
- [ ] the event's data has no `request_body` or `response_body` key, and no value in it contains the fixture's request text.
- [ ] a failed turn emits one event with `outcome: "error"` and its error string.
- [ ] `Agento.EventBusBridge.discover_topics/0` includes `hub.request`.

- [ ] Write the tests, watch them fail, implement, watch them pass. Full suite. Commit.

### Task 8: Run as a service (agento)

**Files:**

- Modify: `config/runtime.exs`
- Create: `rel/agento.service.in` (unit template), `scripts/install-service.tcl`, `test/tcl/install_service_test.tcl`
- Modify: `README.md` (a "Private LLM hub" section)

**Interfaces:**

- Consumes: everything above.
- Produces: an install script the operator runs; a README section with client setup.

Behaviour of `config/runtime.exs`:

- The bind address comes from `AGENTO_BIND`, default `127.0.0.1`, in every environment. The prod block no longer binds every interface. An address that does not parse is a boot error naming the variable.
- In prod, `PORT` defaults to 4141.
- Everything else in the file is unchanged.

Behaviour of `scripts/install-service.tcl`, run as `tclsh scripts/install-service.tcl ?--prefix DIR? ?--dry-run?`:

- `--prefix` (default the user's home) is the root under which everything is written, so tests can use a temp directory.
- It refuses to run if `mix` or `tclsh` is missing, saying which.
- It builds assets and the release (`MIX_ENV=prod mix assets.deploy`, `MIX_ENV=prod mix release --path <prefix>/.local/lib/agento --overwrite`).
- It writes, only if absent, `<prefix>/.config/agento/hub.edn` (mode 0600) with one client named `claude-code` and a freshly generated 32-byte random token, and `<prefix>/.config/agento/env` (mode 0600) with a generated `SECRET_KEY_BASE`, `PHX_SERVER=true`, `PORT=4141`, `PHX_HOST=localhost`, `AGENTO_BIND=127.0.0.1`. It never overwrites either file.
- It writes `<prefix>/.config/systemd/user/agento.service` from the template: `EnvironmentFile` the env file, `ExecStart` the release's `bin/agento start`, `WorkingDirectory` `<prefix>/.local/share/agento` (created; the durable event log is written relative to it), `Restart=on-failure`.
- It does not call `systemctl`. It prints the three commands the operator runs to enable and start the unit, and the two environment variables to set for Claude Code, with the generated token.
- `--dry-run` prints what it would write and build, and writes nothing.

Tests (`tcltest`; stub the build step through an environment variable so the test does not build a release):

- [ ] a run against an empty temp prefix writes the three files; `hub.edn` and `env` are mode 0600; the unit file contains the prefix's paths and no unexpanded template markers.
- [ ] the generated `hub.edn` is accepted by `Agento.Hub.Config.load/1` (one ExUnit test that runs the script with the stubbed build and loads the result).
- [ ] a second run leaves `hub.edn` and `env` byte-identical.
- [ ] `--dry-run` writes nothing.
- [ ] two fresh runs generate different tokens.

Acceptance, against a real release under a scratch prefix in `/tmp` (no systemd involved; start the release by hand with the generated env file, on a free port):

- [ ] `ss -ltnp` shows the release listening on `127.0.0.1` only.
- [ ] with `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN` set from the script's output, `claude -p` answers a prompt that requires the Read tool on a file containing a known word, and the answer contains the word.
- [ ] the same command with a wrong token fails with an authentication error.
- [ ] `hub_turns.sqlite` under the scratch prefix has rows for those turns with `outcome`, token counts, and both bodies; read them through `bin/agento rpc`.
- [ ] the release has been up for more than two minutes and `GET /v1/models` still lists the live hosts' models. This is Task 1 holding in production shape.
- [ ] stop the release; nothing is left listening and no `tclsh` or `avahi-browse` process remains.
- [ ] Record the commands and their observed results in the commit message.

README section:

- [ ] what the hub is; the install command; the three `systemctl --user` commands; Claude Code setup (`ANTHROPIC_BASE_URL=http://127.0.0.1:4141`, `ANTHROPIC_AUTH_TOKEN=<token>`); where the config, the turn log, and the logs live; that the first turn of a session takes minutes on a large prompt; that pointing Claude Code at the hub takes it off a Claude subscription for that session, and that the hub never forwards to a paid API in this build; a `pi` `models.json` example marked as untested.

- [ ] `mix precommit`. Commit.

## After this plan

Merge both branches. The operator runs the install script and enables the unit. The next plan covers OpenAI Chat ingress (with a request captured from a real OpenAI-protocol client), cloud performers behind the spec's three opt-ins (and, first, the adapter's redirect and buffer-cap fixes), and Anemos routing.

# Tool Substrate Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate all twelve native tools from the legacy `LLMAgent.Tools.<Name>.perform/2` registry onto the tool-discovery substrate (`%ToolAd{}` + per-kind behaviour callbacks + `Tool.Dispatcher` + `%Policy{}`), then flip the agent's dispatch path to invoke through the substrate. Finish the in-flight approval-flow scaffolding (commit `42e0964`) with tests as part of the dispatch-path work. End state: every native tool resolvable by coordinate, every dispatch flows through `Tool.Dispatcher`, deny-by-default policy is the single trust enforcement point.

**Architecture:** Per §7 of `docs/superpowers/specs/2026-05-03-tool-discovery-design.md`. Each tool gains `ad/0` returning a `%ToolAd{}` and implements one or more kind behaviours (`Compute` / `Query` / `Action` / `Stream` / `Coordinate` / `Spawn`). The old `perform/2` stays as a shim so legacy callers keep working until §7.10 subtraction (out of scope here). Ads are registered at boot from a new `LLMAgent.Tools.Builtins.register_all/0`. The agent's `dispatch_tool` path is rewritten to call `Tool.Dispatcher.<kind>/4` with a `%Policy{}` derived from the agent's `allowed_tools` via `Policy.from_legacy_or_struct/1`. The tree must stay green at every commit.

**Tech Stack:** Elixir / OTP. `:persistent_term` registries (already in place for kinds + bindings). ETS for the discovery store. `Comn.Errors.ErrorStruct`. `Comn.Events` via `LLMAgent.Events.emit/4`. ExUnit for tests.

---

## Scope

In scope: §7.2 (coordinate assignments), §7.3 (per-tool migration shape), §7.4 (coexistence shim — `legacy_coordinate_for/1`), §7.5 (agent dispatch path), §7.6 steps 2–8 (all tool migrations + dispatch path), §7.8 in spirit (approval-flow tests, since they belong on the Dispatcher).

Out of scope (deferred to a follow-on plan): §7.6 step 9 (LLM-facing catalog regeneration — system prompt still emits legacy `{"tool":"bash",...}` JSON, translated via `legacy_coordinate_for/1`), §7.6 step 10 (subtraction — `perform/2` shims, `:persistent_term` legacy table, and the compat translator stay until a separate cleanup PR).

## Cross-cutting requirements

These apply to every task. Repeat-callers will fail review if any of these is skipped:

1. **TDD.** Write the failing dispatcher-level test BEFORE touching the tool module. Each migration test goes through `Tool.Dispatcher.<kind>/4` with a real `%Policy{}` — not by calling the new kind callback directly.
2. **Integration test, not unit.** Per [[feedback_discovery_integration_tests]]: register the ad in `LLMAgent.Tools.Discovery`, dispatch by coordinate string (not by passing the `%ToolAd{}`), assert. Unit tests on the new callback are welcome but cannot stand alone.
3. **Keep `perform/2` working.** Every existing test that calls `LLMAgent.Tools.<Name>.perform/2` must keep passing. The migration adds new entry points; it does not remove old ones.
4. **Per-tool PR, one commit per task.** Migrating two tools in one commit is forbidden — keeps blame and bisection clean.
5. **Per [[feedback_subagent_git_safety]]:** subagent dispatch prompts MUST forbid `git rebase`, `git reset --hard`, `git push --force`, `git branch -D`, `git filter-branch`. Subagents commit on the current branch; do not switch branches.
6. **Per [[feedback_beam_style_term]]:** if any new callback signature returns a permissive `term()`, route it through a named `@type` alias on the kind module — the beam-style-guard treats raw `term()` returns as a smell.
7. **Run `mix test` after every change** (not just the new test). The agent loop, MCP, tuple space, and discovery tests all exercise the legacy path and must stay green.

## Parallelism

Tasks 2 (Crypto) and 16 (Bash) are solo passes — Crypto validates the per-tool template, Bash is last because of blast radius. Tasks in waves 2–5 may be fanned out 2–4 in parallel via subagent-driven development, since they touch independent files:

- **Wave 2 (after Crypto green):** Net + Proc — parallel
- **Wave 3:** Inotify + Udev — parallel
- **Wave 4:** File + Web + Systemd + DBus — parallel
- **Wave 5:** TupleSpace + Agent — parallel
- **Wave 6:** Bash — solo
- **Wave 7:** Coexistence-shim + Dispatch path + Approval tests + E2E — sequential

Each subagent must be dispatched with a prompt that names the exact task number in this file, the cross-cutting requirements, the git-safety constraints, and the bounded file paths it is allowed to touch.

---

## File Structure

### New files

- `lib/llmagent/tools/builtins.ex` — `register_all/0` builds and registers all twelve `%ToolAd{}` records at boot. Called from `LLMAgent.Application.start/2` immediately after `LLMAgent.Tools.Discovery` starts.
- `test/llmagent/tools/builtins_test.exs` — verifies all twelve ads register and are findable by coordinate.
- `test/llmagent/tool/approval_flow_test.exs` — tests for the in-flight `require_approval` / `request_approval` / `approve` scaffolding shipped in commit `42e0964`.

### Files modified per tool

For each of the twelve tools, exactly two files change:

- `lib/tools/<tool>.ex` — add `@behaviour LLMAgent.Tool.Kinds.<Kind>` line(s), add the kind callback(s) (each delegating to the existing `perform/2` body — DRY), keep `perform/2` as the shim.
- `test/tools/<tool>_test.exs` — add an integration test block that dispatches through `Tool.Dispatcher` by coordinate.

### Other files modified

- `lib/llmagent/application.ex` — one extra line in `start/2` after `LLMAgent.Tools.Discovery` is in the supervision tree: `LLMAgent.Tools.Builtins.register_all()`.
- `lib/LLMAgent.ex` — `dispatch_tool/3` (currently `lib/LLMAgent.ex:249-257`) replaced with a `Tool.Dispatcher` call; `state.allowed_tools` translated via `Policy.from_legacy_or_struct/1`. The `parse_tool_call/1` and `tool_call?/1` helpers keep emitting/expecting the legacy `{"tool":..., "action":..., "args":...}` JSON (catalog regen is out of scope) — a private `legacy_coordinate_for/1` map converts the legacy atom to a coordinate before the Dispatcher call.
- `lib/llmagent/tool/dispatcher.ex` — no behavioural change; the approval-flow code (already committed in `42e0964`) gets tests added in Task 17.

---

## §7.2 — Coordinate assignments (reference)

Per the spec. Engineers MUST use these exact strings:

| Tool | Coordinate | Kinds | Idempotency / Blast radius |
| --- | --- | --- | --- |
| Crypto | `function.crypto` | `[:compute]` | per-action `:idempotent` / `:pure` |
| Net | `resource.network` | `[:query]` | all actions `:idempotent` / `:local` |
| Proc | `resource.proc` | `[:query]` | all actions `:idempotent` / `:local` |
| Inotify | `resource.fs.events` | `[:stream]` | n/a / `:local` |
| Udev | `resource.hardware.events` | `[:stream]` | n/a / `:local` |
| File | `resource.fs.file` | `[:query, :action]` | `read`→idempotent/local; `write`/`delete`→non_idempotent/local |
| Web | `function.http` | `[:query, :action]` | GET/HEAD idempotent/external; POST/PUT/DELETE non_idempotent/external |
| Systemd | `function.systemd` | `[:query, :action]` | `status`/`list` idempotent/local; `start`/`stop`/`restart` non_idempotent/system |
| DBus | `function.dbus` | `[:coordinate, :query, :action]` | per-call; default non_idempotent/system |
| TupleSpace | `function.coordination.tuplespace` | `[:coordinate, :query, :action]` | `rd`/`rd_nowait` idempotent/local; `out`/`in`/`take` non_idempotent/local |
| Agent | `function.agent` | `[:spawn]` | n/a / `:system` |
| Bash | `function.shell.bash` | `[:action]` | `exec` non_idempotent / `:system` |

---

## §7.3 — Per-tool migration shape (the template)

This is the template every per-tool task follows. Read it once before starting Task 2.

```elixir
defmodule LLMAgent.Tools.<Name> do
  @moduledoc "..."

  # Legacy umbrella behaviour — kept for backwards compat with Tools.get/1 callers.
  @behaviour LLMAgent.Tool

  # New kind behaviour(s) — exactly one @behaviour line per declared kind.
  @behaviour LLMAgent.Tool.Kinds.<Kind>

  # ... existing aliases ...

  @doc "Authoritative tool ad. Called by LLMAgent.Tools.Builtins.register_all/0."
  @spec ad() :: LLMAgent.ToolAd.t()
  def ad do
    LLMAgent.ToolAd.new(%{
      id: "builtin.<name>",
      coordinate: "<coordinate from §7.2 table>",
      kinds: [<kinds from §7.2 table>],
      binding: {:module, __MODULE__},
      operational: %{
        actions: %{
          "<action>" => %{inputs: %{}, outputs: %{}, pre: nil, post: nil},
          # ... one entry per action this tool supports ...
        }
      },
      constraint: %{
        idempotency: %{"<action>" => :idempotent | :non_idempotent | :unknown, ...},
        blast_radius: %{"<action>" => :pure | :local | :system | :external | :unknown, ...}
      },
      affordance: %{declared: [], learned: [], open: false},
      fidelity: :authoritative,
      provenance: %{
        source: "llmagent.builtin",
        produced_at: ~U[2026-05-18 00:00:00Z],
        based_on: [],
        signature: nil
      },
      lease: :permanent,
      meta: %{}
    })
  end

  # --- NEW: kind callback(s). Each delegates to perform/2 to avoid duplicating logic. ---

  @impl LLMAgent.Tool.Kinds.<Kind>
  def <kind_callback>(action, args, ...) do
    case perform(action, args) do
      {:ok, %{output: out, metadata: meta}} -> {:ok, out, meta}     # for :query, :action
      {:ok, %{output: out}} -> {:ok, out}                            # for :compute
      {:error, _} = err -> err
    end
  end

  # --- EXISTING: describe/0 and perform/2 stay untouched. ---

  @impl LLMAgent.Tool
  def describe, do: "..."

  @impl LLMAgent.Tool
  def perform("...", ...), do: ...
end
```

**Return-shape mapping** (the only thing per-kind that varies):

| Kind | Callback | Success shape | Error shape |
| --- | --- | --- | --- |
| `:compute` | `compute(action, args)` | `{:ok, value}` | `{:error, reason}` |
| `:query` | `query(action, args)` | `{:ok, value, meta}` | `{:error, reason}` |
| `:action` | `act(action, args, idempotency_key)` | `{:ok, ack, meta}` | `{:error, reason}` |
| `:stream` | `subscribe(action, args, subscriber)` / `unsubscribe(sub_ref)` | `{:ok, sub_ref}` | `{:error, reason}` |
| `:coordinate` | `participate(role, args, opts)` / `leave(participation_ref)` | `{:ok, ref}` | `{:error, reason}` |
| `:spawn` | `spawn_child(spec, opts)` / `child_status(ref)` / `terminate_child(ref, reason)` | `{:ok, child_ref}` | `{:error, reason}` |

Tools that declare multiple kinds (e.g., File = `[:query, :action]`) implement multiple kind behaviours and dispatch the new callbacks to `perform/2` based on action name.

---

## Tasks

### Task 1: Pre-flight — verify baseline

**Files:**
- None modified.

- [ ] **Step 1: Confirm working tree is clean**

Run: `git status --short`
Expected: empty output (no modified or untracked files).

- [ ] **Step 2: Confirm we're at the expected starting commit**

Run: `git log --oneline -3`
Expected: top commit is `WIP — approval-flow scaffolding on Tool.Dispatcher` (`42e0964`), second is `Add RolePrompt.roles/0 — closes #1` (`32d4e8f`).

- [ ] **Step 3: Run the full test suite as baseline**

Run: `mix test 2>&1 | tail -5`
Expected: `0 failures` (128 doctests, 366 tests as of `42e0964` — counts will go up as new tests land).

- [ ] **Step 4: Note the leaked-port-process warning**

The existing test suite leaks `avahi-browse` and `inotifywait` processes that survive BEAM shutdown. After `mix test` exits, run:

```bash
ps -ef | grep -E "avahi-browse|inotifywait|tclsh" | grep -v grep | wc -l
```

If non-zero, kill them:

```bash
pkill -f "avahi-llama.tcl"; pkill -f "avahi-browse -p -r _llama"; pkill -f "inotifywait -m --format %e %w%f /tmp/inotify_test"
```

This is a known issue (tracked separately from this plan) but biting it once now will save grief during the migration.

---

### Task 2: Migrate Crypto (`:compute`) — validates the template

**Files:**
- Modify: `lib/tools/crypto.ex`
- Test: `test/tools/crypto_test.exs`

This is the simplest migration (one kind, no side effects, no metadata to thread) and must be merged before any other tool migration starts. Subsequent tasks reuse the same shape.

- [ ] **Step 1: Write the failing dispatcher-integration test**

Append the following describe block to `test/tools/crypto_test.exs`:

```elixir
  describe "tool-discovery substrate (via Dispatcher)" do
    alias LLMAgent.{Tools.Crypto, Tools.Discovery, Tool.Dispatcher, Tool.Policy}

    setup do
      case Process.whereis(Discovery) do
        nil -> {:ok, _} = Discovery.start_link(consume_announcements: false)
        _ -> Discovery.reset!()
      end

      LLMAgent.Tool.Bindings.init_registry()
      LLMAgent.Tool.Kinds.init_registry()
      :ok = Discovery.register(Crypto.ad())
      :ok
    end

    test "ad/0 returns a well-formed ToolAd for function.crypto" do
      ad = Crypto.ad()
      assert ad.coordinate == "function.crypto"
      assert :compute in ad.kinds
      assert ad.binding == {:module, Crypto}
      assert ad.fidelity == :authoritative
    end

    test "dispatcher.compute/4 sha256 returns the digest" do
      policy = %Policy{allow: ["function.crypto"], fidelity_min: :authoritative}

      assert {:ok, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"} =
               Dispatcher.compute("function.crypto", "sha256", %{"data" => "hello"},
                 policy: policy)
    end

    test "dispatcher denies when policy.allow is empty" do
      assert {:error, :forbidden, :not_allowed} =
               Dispatcher.compute("function.crypto", "sha256", %{"data" => "hello"},
                 policy: %Policy{})
    end
  end
```

- [ ] **Step 2: Run it — expect failure**

Run: `mix test test/tools/crypto_test.exs:53 --trace 2>&1 | tail -20`
(Line number is approximate — adjust to wherever the new describe block lands.)
Expected: tests fail because `Crypto.ad/0` is undefined and `@behaviour LLMAgent.Tool.Kinds.Compute` is not implemented.

- [ ] **Step 3: Add the kind behaviour, `ad/0`, and the `compute/2` callback**

Edit `lib/tools/crypto.ex`. After the existing `@behaviour LLMAgent.Tool` line (around line 14), add:

```elixir
  @behaviour LLMAgent.Tool.Kinds.Compute
```

Before the existing `@impl true def describe do` (around line 27), insert the `ad/0` function:

```elixir
  @doc "Authoritative tool ad. Registered at boot by `LLMAgent.Tools.Builtins`."
  @spec ad() :: LLMAgent.ToolAd.t()
  def ad do
    actions = ~w(sha256 hmac generate_key generate_keypair sign verify)

    LLMAgent.ToolAd.new(%{
      id: "builtin.crypto",
      coordinate: "function.crypto",
      kinds: [:compute],
      binding: {:module, __MODULE__},
      operational: %{
        actions:
          Map.new(actions, fn a ->
            {a, %{inputs: %{}, outputs: %{}, pre: nil, post: nil}}
          end)
      },
      constraint: %{
        idempotency: Map.new(actions, &{&1, :idempotent}),
        blast_radius: Map.new(actions, &{&1, :pure})
      },
      affordance: %{
        declared: [
          %{
            intent: "hash, sign, verify, or generate cryptographic material",
            suits: "any tool/agent that needs deterministic crypto operations",
            avoid_when: "the input must be kept off-disk — Crypto returns base64/hex by default"
          }
        ],
        learned: [],
        open: false
      },
      fidelity: :authoritative,
      provenance: %{
        source: "llmagent.builtin",
        produced_at: ~U[2026-05-18 00:00:00Z],
        based_on: [],
        signature: nil
      },
      lease: :permanent,
      meta: %{}
    })
  end
```

Then add the `compute/2` callback at the end of the module (before the final `end`):

```elixir
  @impl LLMAgent.Tool.Kinds.Compute
  def compute(action, args) do
    case perform(action, args) do
      {:ok, %{output: out}} -> {:ok, out}
      {:error, _} = err -> err
    end
  end
```

- [ ] **Step 4: Run the test — expect pass**

Run: `mix test test/tools/crypto_test.exs --trace 2>&1 | tail -20`
Expected: all Crypto tests pass, including the new dispatcher-integration tests.

- [ ] **Step 5: Run the full test suite — verify nothing else broke**

Run: `mix test 2>&1 | tail -5`
Expected: `0 failures` (test count up by 3).

- [ ] **Step 6: Commit**

```bash
git add lib/tools/crypto.ex test/tools/crypto_test.exs
git commit -m "Migrate Crypto to tool-discovery substrate (§7.2)

Adds @behaviour LLMAgent.Tool.Kinds.Compute, ad/0 returning the
authoritative %ToolAd{} for coordinate function.crypto, and a
compute/2 callback that delegates to the existing perform/2. The
legacy perform/2 stays as a shim for pre-substrate callers.

First per-tool migration per the per-tool template in
docs/superpowers/plans/2026-05-18-tool-substrate-migration.md §7.3."
```

---

### Task 3: Migrate Net (`:query`)

**Files:**
- Modify: `lib/tools/net.ex`
- Test: `test/tools/net_test.exs`

- [ ] **Step 1: Write the failing dispatcher-integration test**

Append to `test/tools/net_test.exs`:

```elixir
  describe "tool-discovery substrate (via Dispatcher)" do
    alias LLMAgent.{Tools.Net, Tools.Discovery, Tool.Dispatcher, Tool.Policy}

    setup do
      case Process.whereis(Discovery) do
        nil -> {:ok, _} = Discovery.start_link(consume_announcements: false)
        _ -> Discovery.reset!()
      end

      LLMAgent.Tool.Bindings.init_registry()
      LLMAgent.Tool.Kinds.init_registry()
      :ok = Discovery.register(Net.ad())
      :ok
    end

    test "ad/0 returns a ToolAd for resource.network with :query kind" do
      ad = Net.ad()
      assert ad.coordinate == "resource.network"
      assert :query in ad.kinds
      assert ad.fidelity == :authoritative
    end

    test "dispatcher.query/4 list_interfaces returns a value+meta tuple" do
      policy = %Policy{allow: ["resource.network"], fidelity_min: :authoritative}

      assert {:ok, value, meta} =
               Dispatcher.query("resource.network", "list_interfaces", %{}, policy: policy)

      assert is_list(value) or is_map(value)
      assert is_map(meta)
    end
  end
```

- [ ] **Step 2: Run — expect failure**

Run: `mix test test/tools/net_test.exs 2>&1 | tail -20`
Expected: `Net.ad/0` undefined.

- [ ] **Step 3: Add behaviour, ad/0, and query/2 callback**

Edit `lib/tools/net.ex`. Add `@behaviour LLMAgent.Tool.Kinds.Query` next to the existing `@behaviour LLMAgent.Tool`. Add `ad/0`:

```elixir
  @doc "Authoritative tool ad."
  @spec ad() :: LLMAgent.ToolAd.t()
  def ad do
    actions = ~w(list_interfaces ping resolve)

    LLMAgent.ToolAd.new(%{
      id: "builtin.net",
      coordinate: "resource.network",
      kinds: [:query],
      binding: {:module, __MODULE__},
      operational: %{
        actions: Map.new(actions, &{&1, %{inputs: %{}, outputs: %{}, pre: nil, post: nil}})
      },
      constraint: %{
        idempotency: Map.new(actions, &{&1, :idempotent}),
        blast_radius: Map.new(actions, &{&1, :local})
      },
      affordance: %{
        declared: [
          %{intent: "inspect local network state", suits: "diagnostic and discovery flows", avoid_when: nil}
        ],
        learned: [],
        open: false
      },
      fidelity: :authoritative,
      provenance: %{source: "llmagent.builtin", produced_at: ~U[2026-05-18 00:00:00Z], based_on: [], signature: nil},
      lease: :permanent,
      meta: %{}
    })
  end
```

Add the `query/2` callback before the final `end`:

```elixir
  @impl LLMAgent.Tool.Kinds.Query
  def query(action, args) do
    case perform(action, args) do
      {:ok, %{output: out, metadata: meta}} -> {:ok, out, meta}
      {:error, _} = err -> err
    end
  end
```

- [ ] **Step 4: Run — expect pass**

Run: `mix test test/tools/net_test.exs 2>&1 | tail -10`
Expected: pass.

- [ ] **Step 5: Run full suite**

Run: `mix test 2>&1 | tail -5`
Expected: `0 failures`.

- [ ] **Step 6: Commit**

```bash
git add lib/tools/net.ex test/tools/net_test.exs
git commit -m "Migrate Net to tool-discovery substrate (§7.2)

Coordinate: resource.network. Kinds: [:query]. perform/2 retained as
backwards-compat shim. query/2 delegates to perform/2 to avoid
duplicating action logic."
```

---

### Task 4: Migrate Proc (`:query`)

**Files:**
- Modify: `lib/tools/proc.ex`
- Test: `test/tools/proc_test.exs`

Identical shape to Task 3 (Net) — substitute Proc / `resource.proc` / actions `~w(list info)`. The `affordance.declared` should read:

```elixir
[%{intent: "inspect running processes via /proc", suits: "diagnostic queries", avoid_when: nil}]
```

- [ ] **Step 1: Write the failing dispatcher-integration test**

Append the same shape as Task 3 to `test/tools/proc_test.exs`, with:
- `alias LLMAgent.Tools.Proc`
- `:ok = Discovery.register(Proc.ad())`
- `assert ad.coordinate == "resource.proc"`
- Dispatcher call: `Dispatcher.query("resource.proc", "list", %{}, policy: %Policy{allow: ["resource.proc"], fidelity_min: :authoritative})`

- [ ] **Step 2: Run — expect failure**

Run: `mix test test/tools/proc_test.exs 2>&1 | tail -20`
Expected: `Proc.ad/0` undefined.

- [ ] **Step 3: Add behaviour, ad/0, query/2 to `lib/tools/proc.ex`**

Same shape as Task 3. Set `id: "builtin.proc"`, `coordinate: "resource.proc"`, `actions = ~w(list info)`, all `:idempotent` / `:local`.

- [ ] **Step 4: Run test — pass**

Run: `mix test test/tools/proc_test.exs 2>&1 | tail -10`

- [ ] **Step 5: Run full suite**

Run: `mix test 2>&1 | tail -5`
Expected: `0 failures`.

- [ ] **Step 6: Commit**

```bash
git add lib/tools/proc.ex test/tools/proc_test.exs
git commit -m "Migrate Proc to tool-discovery substrate (§7.2)

Coordinate: resource.proc. Kinds: [:query]. perform/2 retained."
```

---

### Task 5: Migrate Inotify (`:stream`)

**Files:**
- Modify: `lib/tools/inotify.ex`
- Test: `test/tools/inotify_test.exs`

Inotify is the first `:stream` tool. Its kind callbacks are `subscribe/3` and `unsubscribe/1`. The existing `perform/2` actions (`watch`, `poll`, `stop`, `list`) DO NOT map cleanly onto the `:stream` model — `:stream` is a long-running subscription, while `watch`/`poll` is a manual buffer-and-poll pattern. We keep `perform/2` working as before AND expose a NEW `subscribe/3` callback that wraps `Inotify.Watcher` differently: on subscribe, start a forwarder process that sends `{:stream_event, sub_ref, event}` to the subscriber for each fs event.

If implementing the forwarder is more than 30 minutes of work, scope it down to: `subscribe/3` accepts `action = "watch"`, args `%{"path" => p}`, returns `{:ok, sub_ref}` where `sub_ref` is the existing `watch_id` wrapped in a tuple `{:inotify_watch, watch_id}`. The forwarder/streaming behaviour is a follow-on. The ad still declares `:stream`.

- [ ] **Step 1: Write the failing test**

Append to `test/tools/inotify_test.exs`:

```elixir
  describe "tool-discovery substrate (via Dispatcher)" do
    alias LLMAgent.{Tools.Inotify, Tools.Discovery, Tool.Dispatcher, Tool.Policy}

    setup do
      case Process.whereis(Discovery) do
        nil -> {:ok, _} = Discovery.start_link(consume_announcements: false)
        _ -> Discovery.reset!()
      end

      LLMAgent.Tool.Bindings.init_registry()
      LLMAgent.Tool.Kinds.init_registry()
      :ok = Discovery.register(Inotify.ad())
      :ok
    end

    test "ad/0 returns a ToolAd for resource.fs.events with :stream kind" do
      ad = Inotify.ad()
      assert ad.coordinate == "resource.fs.events"
      assert :stream in ad.kinds
    end

    @tag :tmp_dir
    test "dispatcher.subscribe/5 watch returns {:ok, sub_ref}", %{tmp_dir: dir} do
      policy = %Policy{allow: ["resource.fs.events"], fidelity_min: :authoritative}

      {:ok, sub_ref} =
        Dispatcher.subscribe("resource.fs.events", "watch", %{"path" => dir},
          self(), policy: policy)

      assert match?({:inotify_watch, _}, sub_ref)
    end
  end
```

- [ ] **Step 2: Run — expect failure**

Run: `mix test test/tools/inotify_test.exs 2>&1 | tail -20`

- [ ] **Step 3: Add behaviour, ad/0, and `subscribe/3` + `unsubscribe/1` to `lib/tools/inotify.ex`**

Add `@behaviour LLMAgent.Tool.Kinds.Stream` and:

```elixir
  @doc "Authoritative tool ad."
  @spec ad() :: LLMAgent.ToolAd.t()
  def ad do
    LLMAgent.ToolAd.new(%{
      id: "builtin.inotify",
      coordinate: "resource.fs.events",
      kinds: [:stream],
      binding: {:module, __MODULE__},
      operational: %{
        actions: %{
          "watch" => %{inputs: %{}, outputs: %{}, pre: nil, post: nil}
        }
      },
      constraint: %{
        idempotency: %{"watch" => :unknown},
        blast_radius: %{"watch" => :local}
      },
      affordance: %{
        declared: [%{intent: "subscribe to filesystem events for a path", suits: "fs change detection", avoid_when: "the path does not exist yet"}],
        learned: [],
        open: false
      },
      fidelity: :authoritative,
      provenance: %{source: "llmagent.builtin", produced_at: ~U[2026-05-18 00:00:00Z], based_on: [], signature: nil},
      lease: :permanent,
      meta: %{}
    })
  end

  @impl LLMAgent.Tool.Kinds.Stream
  def subscribe("watch", %{"path" => path}, _subscriber) do
    case perform("watch", %{"path" => path}) do
      {:ok, %{output: watch_id}} -> {:ok, {:inotify_watch, watch_id}}
      {:error, _} = err -> err
    end
  end

  def subscribe(_, _, _), do: {:error, :unknown_action}

  @impl LLMAgent.Tool.Kinds.Stream
  def unsubscribe({:inotify_watch, watch_id}) do
    case perform("stop", %{"watch_id" => watch_id}) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  def unsubscribe(_), do: {:error, :invalid_sub_ref}
```

(The forwarder process that converts buffered events into `{:stream_event, sub_ref, event}` messages is deliberately deferred — `subscribe/3` ignores the `subscriber` pid for now. A follow-on plan lifts this into a real streaming subscription.)

- [ ] **Step 4: Run test — pass**

Run: `mix test test/tools/inotify_test.exs 2>&1 | tail -10`

- [ ] **Step 5: Full suite**

Run: `mix test 2>&1 | tail -5`

- [ ] **Step 6: Commit**

```bash
git add lib/tools/inotify.ex test/tools/inotify_test.exs
git commit -m "Migrate Inotify to tool-discovery substrate (§7.2)

Coordinate: resource.fs.events. Kinds: [:stream]. subscribe/3 wraps
the existing watch_id model; true event-stream forwarding deferred."
```

---

### Task 6: Migrate Udev (`:stream`)

**Files:**
- Modify: `lib/tools/udev.ex`
- Test: `test/tools/udev_test.exs`

Same shape as Task 5 (Inotify). Coordinate `resource.hardware.events`. Udev's `perform/2` exposes `list`, `info`, `usb`, `pci` — which are actually `:query`-shaped, not `:stream`. So the ad declares `[:query]`, not `[:stream]` — confirm by reading `lib/tools/udev.ex` first, and reclassify if necessary (this is the most likely place the spec's table is wrong about Udev).

If the existing `udev.ex` is purely query-shaped (no live monitoring), file an inline comment and use `[:query]`. If it has a live udev-monitor port, use `[:stream]` and mirror Task 5.

- [ ] **Step 1: Read `lib/tools/udev.ex` and decide kind**

Run: `head -40 lib/tools/udev.ex`
Decide: pure-query OR stream-capable. Document the decision in the commit message.

- [ ] **Step 2–6: Write test, run/fail, add ad + callbacks, pass, commit.**

If `:query`, mirror Task 3. If `:stream`, mirror Task 5. Use `id: "builtin.udev"`, `coordinate: "resource.hardware.events"`.

```bash
git add lib/tools/udev.ex test/tools/udev_test.exs
git commit -m "Migrate Udev to tool-discovery substrate (§7.2)

Coordinate: resource.hardware.events. Kinds: [<as decided>].
perform/2 retained as shim."
```

---

### Task 7: Migrate File (`:query` + `:action`)

**Files:**
- Modify: `lib/tools/file.ex`
- Test: `test/tools/file_test.exs`

First multi-kind migration. `read` is `:query`. `write` and `delete` are `:action`.

- [ ] **Step 1: Failing test**

Append to `test/tools/file_test.exs`:

```elixir
  describe "tool-discovery substrate (via Dispatcher)" do
    alias LLMAgent.{Tools.File, Tools.Discovery, Tool.Dispatcher, Tool.Policy}

    setup do
      case Process.whereis(Discovery) do
        nil -> {:ok, _} = Discovery.start_link(consume_announcements: false)
        _ -> Discovery.reset!()
      end

      LLMAgent.Tool.Bindings.init_registry()
      LLMAgent.Tool.Kinds.init_registry()
      :ok = Discovery.register(File.ad())
      :ok
    end

    test "ad/0 declares both :query and :action" do
      ad = File.ad()
      assert ad.coordinate == "resource.fs.file"
      assert :query in ad.kinds
      assert :action in ad.kinds
    end

    @tag :tmp_dir
    test "dispatcher.query/4 read returns content", %{tmp_dir: dir} do
      path = Path.join(dir, "hello.txt")
      Elixir.File.write!(path, "world")

      policy = %Policy{
        allow: [%{coordinate: "resource.fs.file", kinds: [:query], actions: ["read"]}],
        fidelity_min: :authoritative
      }

      assert {:ok, "world", _meta} =
               Dispatcher.query("resource.fs.file", "read", %{"path" => path}, policy: policy)
    end

    @tag :tmp_dir
    test "dispatcher.act/5 write succeeds", %{tmp_dir: dir} do
      path = Path.join(dir, "out.txt")

      policy = %Policy{
        allow: [%{coordinate: "resource.fs.file", kinds: [:action], actions: ["write"]}],
        fidelity_min: :authoritative
      }

      assert {:ok, _ack, _meta} =
               Dispatcher.act("resource.fs.file", "write",
                 %{"path" => path, "content" => "hi"}, nil, policy: policy)

      assert Elixir.File.read!(path) == "hi"
    end
  end
```

- [ ] **Step 2: Run — fail**

Run: `mix test test/tools/file_test.exs 2>&1 | tail -20`

- [ ] **Step 3: Add behaviours, ad/0, query/2, act/3**

```elixir
  @behaviour LLMAgent.Tool.Kinds.Query
  @behaviour LLMAgent.Tool.Kinds.Action

  @spec ad() :: LLMAgent.ToolAd.t()
  def ad do
    LLMAgent.ToolAd.new(%{
      id: "builtin.file",
      coordinate: "resource.fs.file",
      kinds: [:query, :action],
      binding: {:module, __MODULE__},
      operational: %{
        actions: %{
          "read"   => %{inputs: %{}, outputs: %{}, pre: nil, post: nil},
          "write"  => %{inputs: %{}, outputs: %{}, pre: nil, post: nil},
          "delete" => %{inputs: %{}, outputs: %{}, pre: nil, post: nil}
        }
      },
      constraint: %{
        idempotency: %{"read" => :idempotent, "write" => :non_idempotent, "delete" => :non_idempotent},
        blast_radius: %{"read" => :local, "write" => :local, "delete" => :local}
      },
      affordance: %{declared: [%{intent: "read/write/delete files", suits: "any file IO", avoid_when: "the path is on a remote mount with high latency"}], learned: [], open: false},
      fidelity: :authoritative,
      provenance: %{source: "llmagent.builtin", produced_at: ~U[2026-05-18 00:00:00Z], based_on: [], signature: nil},
      lease: :permanent,
      meta: %{}
    })
  end

  @impl LLMAgent.Tool.Kinds.Query
  def query("read", args) do
    case perform("read", args) do
      {:ok, %{output: out, metadata: meta}} -> {:ok, out, meta}
      {:error, _} = err -> err
    end
  end

  def query(_, _), do: {:error, :unknown_action}

  @impl LLMAgent.Tool.Kinds.Action
  def act(action, args, _idempotency_key) when action in ["write", "delete"] do
    case perform(action, args) do
      {:ok, %{output: out, metadata: meta}} -> {:ok, out, meta}
      {:error, _} = err -> err
    end
  end

  def act(_, _, _), do: {:error, :unknown_action}
```

- [ ] **Step 4: Run test — pass**

Run: `mix test test/tools/file_test.exs 2>&1 | tail -10`

- [ ] **Step 5: Full suite**

Run: `mix test 2>&1 | tail -5`

- [ ] **Step 6: Commit**

```bash
git add lib/tools/file.ex test/tools/file_test.exs
git commit -m "Migrate File to tool-discovery substrate (§7.2)

Coordinate: resource.fs.file. Kinds: [:query, :action].
read → :query, write/delete → :action. perform/2 retained."
```

---

### Task 8: Migrate Web (`:query` + `:action`)

**Files:**
- Modify: `lib/tools/web.ex`
- Test: `test/tools/web_test.exs`

Same shape as Task 7. `get` and any HEAD/OPTIONS are `:query`; `post`, `put`, `delete`, `patch` are `:action`. Read `lib/tools/web.ex` to enumerate the actual actions — the existing module exposes `get` and `post` per `README.md:69`. Coordinate `function.http`. Blast radius `:external` for all actions.

The dispatcher-integration test should use a `Plug.Cowboy` or `Req.Test` stub OR mark the test `@tag :integration` and skip in CI. The simplest path: `Req.Test.stub/2` to mock the HTTP server inline.

- [ ] **Step 1–6 mirror Task 7**, substituting `function.http` and per-action kind assignment. Idempotency map: GET `:idempotent`, POST/PUT/DELETE `:non_idempotent`. Blast radius: all `:external`.

```bash
git commit -m "Migrate Web to tool-discovery substrate (§7.2)

Coordinate: function.http. Kinds: [:query, :action]."
```

---

### Task 9: Migrate Systemd (`:query` + `:action`)

**Files:**
- Modify: `lib/tools/systemd.ex`
- Test: `test/tools/systemd_test.exs`

Same shape as Task 7. `status`/`list` are `:query`. `start`/`stop`/`restart` are `:action`. Coordinate `function.systemd`. `:action` blast radius `:system`. Tests should use `Mox` or skip integration with `@tag :systemd` since this hits real systemd.

```bash
git commit -m "Migrate Systemd to tool-discovery substrate (§7.2)

Coordinate: function.systemd. Kinds: [:query, :action].
start/stop/restart marked non_idempotent and blast_radius :system."
```

---

### Task 10: Migrate DBus (`:coordinate` + `:query` + `:action`)

**Files:**
- Modify: `lib/tools/dbus.ex`
- Test: `test/tools/dbus_test.exs`

Three kinds. Read `lib/tools/dbus.ex` to map actions:
- `list`, `introspect` → `:query`
- `call` → `:action` (or `:coordinate` if the action represents joining a signal subscription — confirm against the module body)

For `:coordinate`, implement `participate/3` and `leave/1`. If DBus tool has no coordination actions, drop `:coordinate` from the ad and document the deviation in the commit message.

Coordinate `function.dbus`.

```bash
git commit -m "Migrate DBus to tool-discovery substrate (§7.2)

Coordinate: function.dbus. Kinds: [<as appropriate>]."
```

---

### Task 11: Migrate TupleSpace (`:coordinate` + `:query` + `:action`)

**Files:**
- Modify: `lib/tools/tuple_space.ex`
- Test: `test/tools/tuple_space_tool_test.exs`

Per §7.2: `out` → `:coordinate` (publisher role) or `:action` (destructive write). `in`/`take` → `:action` (destructive read). `rd`/`rd_nowait` → `:query` (non-destructive). The action-to-kind mapping in the spec is "settled per-tool in the migration PR" — document the call here:

- `out` → `:action` (it inserts a tuple; `:coordinate` is reserved for true rendezvous)
- `in`, `take` → `:action` (destructive)
- `rd`, `rd_nowait` → `:query` (non-destructive read)
- `:coordinate.participate(:reader, args, opts)` opens a long-lived `:rd`-by-pattern subscription IF the existing module supports it — if not, omit `:coordinate` from the kinds and document.

Coordinate `function.coordination.tuplespace`.

```bash
git commit -m "Migrate TupleSpace to tool-discovery substrate (§7.2)

Coordinate: function.coordination.tuplespace. Kinds: <as decided>.
out/in/take → :action, rd/rd_nowait → :query."
```

---

### Task 12: Migrate Agent (`:spawn`)

**Files:**
- Modify: `lib/tools/agent.ex`
- Test: `test/tools/agent_tool_test.exs`

The Agent tool wraps `LLMAgent.AgentSupervisor.start_agent/1`. Kind is `:spawn`. Implement `spawn_child/2`, `child_status/1`, `terminate_child/2`. Each delegates to the existing `perform/2` actions.

Coordinate `function.agent`. Idempotency: `:unknown`. Blast radius: `:system`.

- [ ] **Step 1: Failing test** dispatches `Dispatcher.spawn_child("function.agent", spec, policy: policy)`.

- [ ] **Step 3: Add `@behaviour LLMAgent.Tool.Kinds.SpawnKind`**, `ad/0`, the three callbacks.

```bash
git commit -m "Migrate Agent to tool-discovery substrate (§7.2)

Coordinate: function.agent. Kinds: [:spawn]."
```

---

### Task 13: Migrate Bash (`:action`) — solo, last

**Files:**
- Modify: `lib/tools/bash.ex`
- Test: `test/tools/bash_test.exs`

Last because of blast radius. Coordinate `function.shell.bash`. Single action `exec` → `:action`. Idempotency `:non_idempotent`, blast radius `:system`. After this commit, every native tool is migrated.

- [ ] **Step 1–6 mirror Task 7** (single kind, single action). The test should use a benign command like `echo hello`.

```bash
git commit -m "Migrate Bash to tool-discovery substrate (§7.2)

Coordinate: function.shell.bash. Kinds: [:action].
All twelve native tools now register authoritative ads at boot."
```

---

### Task 14: Wire `LLMAgent.Tools.Builtins.register_all/0` into boot

**Files:**
- Create: `lib/llmagent/tools/builtins.ex`
- Create: `test/llmagent/tools/builtins_test.exs`
- Modify: `lib/llmagent/application.ex`

Until now, each per-tool test has registered the ad explicitly in its setup block. This task makes the application register all twelve at boot via a single call, so live agents (and the existing application) see the populated registry without any test scaffolding.

- [ ] **Step 1: Write the failing test**

Create `test/llmagent/tools/builtins_test.exs`:

```elixir
defmodule LLMAgent.Tools.BuiltinsTest do
  use ExUnit.Case, async: false

  alias LLMAgent.{Tools.Builtins, Tools.Discovery, ToolQuery}

  setup do
    case Process.whereis(Discovery) do
      nil -> {:ok, _} = Discovery.start_link(consume_announcements: false)
      _ -> Discovery.reset!()
    end

    LLMAgent.Tool.Bindings.init_registry()
    LLMAgent.Tool.Kinds.init_registry()
    :ok
  end

  test "register_all/0 registers every built-in tool ad" do
    :ok = Builtins.register_all()

    expected = [
      "function.crypto",
      "resource.network",
      "resource.proc",
      "resource.fs.events",
      "resource.hardware.events",
      "resource.fs.file",
      "function.http",
      "function.systemd",
      "function.dbus",
      "function.coordination.tuplespace",
      "function.agent",
      "function.shell.bash"
    ]

    for coord <- expected do
      assert {:ok, ad} = Discovery.find_one(ToolQuery.new(%{coordinate: coord}))
      assert ad.fidelity == :authoritative
    end
  end
end
```

- [ ] **Step 2: Run — expect failure**

Run: `mix test test/llmagent/tools/builtins_test.exs 2>&1 | tail -10`

- [ ] **Step 3: Create `lib/llmagent/tools/builtins.ex`**

```elixir
defmodule LLMAgent.Tools.Builtins do
  @moduledoc """
  Registers all built-in tool ads with `LLMAgent.Tools.Discovery` at boot.

  Called from `LLMAgent.Application.start/2` immediately after the Discovery
  GenServer is in the supervision tree. Each tool module exposes `ad/0`
  returning its authoritative `%LLMAgent.ToolAd{}`; this module is just the
  enumeration point so adding a new built-in is a one-line change here plus
  the per-tool `ad/0` implementation.
  """

  alias LLMAgent.Tools

  @builtins [
    Tools.Crypto,
    Tools.Net,
    Tools.Proc,
    Tools.Inotify,
    Tools.Udev,
    Tools.File,
    Tools.Web,
    Tools.Systemd,
    Tools.DBus,
    Tools.TupleSpace,
    Tools.Agent,
    Tools.Bash
  ]

  @doc "Register every built-in tool's ad with `LLMAgent.Tools.Discovery`."
  @spec register_all() :: :ok
  def register_all do
    Enum.each(@builtins, fn mod ->
      :ok = LLMAgent.Tools.Discovery.register(mod.ad())
    end)
  end
end
```

- [ ] **Step 4: Hook it into Application**

Edit `lib/llmagent/application.ex`. After the line `LLMAgent.AgentSupervisor.start_agent(agent_opts)` add (BEFORE `LLMAgent.TupleSpace.start_space(:default)`):

```elixir
    LLMAgent.Tools.Builtins.register_all()
```

Actually the correct order is: register_all/0 needs Discovery to be running (it's in the children list at `application.ex:32`). Insert it AFTER `Supervisor.start_link(...)` succeeds and BEFORE `LLMAgent.AgentSupervisor.start_agent(agent_opts)`:

```elixir
    LLMAgent.Tools.Builtins.register_all()
    LLMAgent.AgentSupervisor.start_agent(agent_opts)
```

- [ ] **Step 5: Run tests**

Run: `mix test test/llmagent/tools/builtins_test.exs 2>&1 | tail -10`
Expected: pass.

Run: `mix test 2>&1 | tail -5`
Expected: `0 failures`.

- [ ] **Step 6: Commit**

```bash
git add lib/llmagent/tools/builtins.ex lib/llmagent/application.ex test/llmagent/tools/builtins_test.exs
git commit -m "Register built-in tool ads at boot via Tools.Builtins

LLMAgent.Tools.Builtins.register_all/0 enumerates the twelve native
tools and registers each tool's ad/0 result with Tools.Discovery.
Called from Application.start/2 after the supervisor comes up."
```

---

### Task 15: Write approval-flow tests (finishes commit `42e0964`)

**Files:**
- Create: `test/llmagent/tool/approval_flow_test.exs`

The approval-flow scaffolding (`require_approval` field, `request_approval/2`, `approve/2`, `maybe_request_approval` in the dispatcher) was committed in `42e0964` without tests. This task adds them.

- [ ] **Step 1: Write the tests**

Create `test/llmagent/tool/approval_flow_test.exs`:

```elixir
defmodule LLMAgent.Tool.ApprovalFlowTest do
  use ExUnit.Case, async: false

  alias LLMAgent.{ToolAd, Tool.Dispatcher, Tool.Policy, Tools.Discovery, EventBus}

  defmodule StubAction do
    @moduledoc false
    @behaviour LLMAgent.Tool.Kinds.Action
    @impl true
    def act("do", _args, _key), do: {:ok, :acked, %{}}
  end

  setup do
    case Process.whereis(Discovery) do
      nil -> {:ok, _} = Discovery.start_link(consume_announcements: false)
      _ -> Discovery.reset!()
    end

    LLMAgent.Tool.Bindings.init_registry()
    LLMAgent.Tool.Kinds.init_registry()
    Dispatcher.init_approvals()

    ad =
      ToolAd.new(%{
        id: "appr.test",
        coordinate: "function.appr",
        kinds: [:action],
        binding: {:module, StubAction},
        operational: %{actions: %{"do" => %{inputs: %{}, outputs: %{}, pre: nil, post: nil}}},
        constraint: %{idempotency: %{"do" => :non_idempotent}, blast_radius: %{"do" => :local}},
        affordance: %{declared: [], learned: [], open: false},
        fidelity: :authoritative,
        provenance: %{source: "test", produced_at: DateTime.utc_now(), based_on: [], signature: nil},
        lease: :permanent,
        meta: %{}
      })

    :ok = Discovery.register(ad)
    {:ok, ad: ad}
  end

  describe "Policy.requires_approval?/4" do
    test "true when a require_approval rule matches", %{ad: ad} do
      policy = %Policy{require_approval: ["function.appr"]}
      assert Policy.requires_approval?(policy, ad, :action, "do")
    end

    test "false when no rule matches", %{ad: ad} do
      assert not Policy.requires_approval?(%Policy{}, ad, :action, "do")
    end
  end

  describe "Dispatcher with require_approval" do
    test "blocks until approve/2 :allow, then completes" do
      policy = %Policy{
        allow: ["function.appr"],
        require_approval: ["function.appr"],
        fidelity_min: :authoritative
      }

      EventBus.subscribe("tool.pending_approval")

      caller = self()

      Task.start(fn ->
        result =
          Dispatcher.act("function.appr", "do", %{"k" => "v"}, nil,
            policy: policy, approval_timeout: 1_000)

        send(caller, {:dispatch_result, result})
      end)

      assert_receive {:event, "tool.pending_approval", event}, 500
      :ok = Dispatcher.approve(event.data.id, :allow)

      assert_receive {:dispatch_result, {:ok, :acked, _}}, 500
    end

    test "deny returns :user_denied" do
      policy = %Policy{
        allow: ["function.appr"],
        require_approval: ["function.appr"],
        fidelity_min: :authoritative
      }

      EventBus.subscribe("tool.pending_approval")
      caller = self()

      Task.start(fn ->
        result =
          Dispatcher.act("function.appr", "do", %{}, nil,
            policy: policy, approval_timeout: 1_000)

        send(caller, {:dispatch_result, result})
      end)

      assert_receive {:event, "tool.pending_approval", event}, 500
      :ok = Dispatcher.approve(event.data.id, :deny)

      assert_receive {:dispatch_result, {:error, :forbidden, :user_denied}}, 500
    end

    test "timeout returns :approval_timeout" do
      policy = %Policy{
        allow: ["function.appr"],
        require_approval: ["function.appr"],
        fidelity_min: :authoritative
      }

      assert {:error, :forbidden, :approval_timeout} =
               Dispatcher.act("function.appr", "do", %{}, nil,
                 policy: policy, approval_timeout: 50)
    end
  end

  describe "approve/2" do
    test "returns :not_found for unknown id" do
      assert {:error, :not_found} = Dispatcher.approve("appr_bogus", :allow)
    end
  end
end
```

- [ ] **Step 2: Run — expect pass (the scaffolding is already implemented)**

Run: `mix test test/llmagent/tool/approval_flow_test.exs --trace 2>&1 | tail -20`
Expected: pass. If any test fails, the scaffolding from `42e0964` has a bug — fix it in the same task (the commit message can promote this from WIP to complete).

- [ ] **Step 3: Run full suite**

Run: `mix test 2>&1 | tail -5`
Expected: `0 failures`.

- [ ] **Step 4: Commit**

```bash
git add test/llmagent/tool/approval_flow_test.exs
git commit -m "Tests for tool-dispatcher approval flow

Covers Policy.requires_approval?/4, Dispatcher allow/deny/timeout
paths, tool.pending_approval event emission, and approve/2 on an
unknown id. Promotes the approval scaffolding from 42e0964 from WIP
to complete."
```

---

### Task 16: Agent dispatch path through `Tool.Dispatcher`

**Files:**
- Modify: `lib/LLMAgent.ex` (`dispatch_tool/3` at line 249–257 and `timed_dispatch/4` at line 214–244)
- Modify: `test/llmagent_test.exs` (or add new file `test/llmagent/dispatch_via_substrate_test.exs`)

This is the §7.5 + §7.8 work. The agent loop's `parse_tool_call/1` still extracts `{:tool_call, :bash, "exec", args}` from the LLM's JSON (legacy format — catalog regen is out of scope). The change is in `dispatch_tool/3`: instead of calling `LLMAgent.Tools.get/1 → mod.perform/2`, translate the legacy atom to a coordinate, build a `%Policy{}` from `state.allowed_tools`, and call `Tool.Dispatcher.<kind>/4`.

- [ ] **Step 1: Write the integration test**

Create `test/llmagent/dispatch_via_substrate_test.exs`:

```elixir
defmodule LLMAgent.DispatchViaSubstrateTest do
  use ExUnit.Case, async: false

  alias LLMAgent.{Tools.Discovery, Tool.Policy}

  defmodule EchoLLMClient do
    @moduledoc false
    @behaviour LLMAgent.LLMClient

    @impl true
    def chat([_system, %{role: "user", content: content} | _], _opts) do
      cond do
        content == "hash this" ->
          {:ok,
           Jason.encode!(%{
             "tool" => "crypto",
             "action" => "sha256",
             "args" => %{"data" => "abc"}
           })}

        true ->
          {:ok, "stopping"}
      end
    end

    @impl true
    def chat([_system | _], _opts), do: {:ok, "stopping"}
  end

  setup do
    Discovery.reset!()
    LLMAgent.Tools.Builtins.register_all()
    :ok
  end

  test "agent loop dispatches a legacy tool call through Tool.Dispatcher" do
    {:ok, _pid} =
      LLMAgent.AgentSupervisor.start_agent(
        name: :substrate_test,
        llm_client: EchoLLMClient,
        allowed_tools: [:crypto]
      )

    on_exit(fn -> LLMAgent.AgentSupervisor.stop_agent(:substrate_test) end)

    LLMAgent.EventBus.subscribe("agent.message")
    LLMAgent.prompt({:global, :substrate_test}, "hash this")

    # Expect: user message, tool dispatch, function message with sha256 hash, final assistant message
    assert_receive {:event, "agent.message", %{data: %{role: "user", content: "hash this"}}}, 1_000
    assert_receive {:event, "agent.message", %{data: %{role: "function", content: payload}}}, 2_000

    assert {:ok, %{"status" => "ok", "output" => hash}} = Jason.decode(payload)
    assert hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  end
end
```

- [ ] **Step 2: Run — expect failure**

Run: `mix test test/llmagent/dispatch_via_substrate_test.exs 2>&1 | tail -20`
Expected: failure — `dispatch_tool/3` still on the legacy path doesn't fail per se, but the test asserts the canonical sha256 of "abc" which the legacy path also produces. The real signal that the path changed is in telemetry; for the purposes of TDD here, also assert:

Add inside the test, before `LLMAgent.prompt(...)`:

```elixir
    :telemetry_test.attach_event_handlers(self(), [[:llmagent, :tool, :compute]])
```

And after the function message assertion:

```elixir
    assert_receive {[:llmagent, :tool, :compute], _, %{coordinate: "function.crypto"}, _}, 1_000
```

That telemetry event is only emitted by `Tool.Dispatcher.dispatch/5` (see `lib/llmagent/tool/dispatcher.ex:239-248`) — so it fires only after the migration. The test fails on the legacy path because no such telemetry event is emitted.

(If `:telemetry_test` isn't already a test-env dependency, add it to `mix.exs` test deps: `{:telemetry_test, "~> 0.1", only: :test}`.)

- [ ] **Step 3: Refactor `dispatch_tool/3`**

In `lib/LLMAgent.ex` around line 249, replace:

```elixir
  defp dispatch_tool(tool, action, args) do
    case Tools.get(tool) do
      {:ok, tool_module} ->
        tool_module.perform(action, args)

      {:error, :not_found} ->
        {:error, ErrorStruct.new("invalid_tool", "tool", "Tool #{tool} not found")}
    end
  end
```

with:

```elixir
  alias LLMAgent.Tool.{Dispatcher, Policy}

  # Map legacy tool atom names to their substrate coordinates. Stays here
  # until §7.6 step 9 (LLM-facing catalog regeneration), then is removed.
  @legacy_coordinate %{
    bash:        {"function.shell.bash",                :action},
    web:         {"function.http",                      nil},        # kind decided per-action
    dbus:        {"function.dbus",                      nil},
    systemd:     {"function.systemd",                   nil},
    inotify:     {"resource.fs.events",                 :stream},
    udev:        {"resource.hardware.events",           nil},
    file:        {"resource.fs.file",                   nil},
    net:         {"resource.network",                   :query},
    proc:        {"resource.proc",                      :query},
    crypto:      {"function.crypto",                    :compute},
    tuple_space: {"function.coordination.tuplespace",   nil},
    agent:       {"function.agent",                     :spawn}
  }

  defp dispatch_tool(tool, action, args, allowed_tools) do
    case Map.fetch(@legacy_coordinate, tool) do
      {:ok, {coordinate, fixed_kind}} ->
        policy = Policy.from_legacy_or_struct(allowed_tools_to_policy(allowed_tools))
        kind = fixed_kind || infer_kind(coordinate, action)
        invoke_via_dispatcher(kind, coordinate, action, args, policy)

      :error ->
        {:error, ErrorStruct.new("invalid_tool", "tool", "Tool #{tool} not found")}
    end
  end

  defp allowed_tools_to_policy(:all) do
    # Permissive: allow every legacy.* AND every substrate coordinate, fidelity authoritative
    %Policy{
      allow: ["function.*", "resource.*", "legacy.*"],
      fidelity_min: :authoritative
    }
  end

  defp allowed_tools_to_policy(list) when is_list(list) do
    coordinates =
      Enum.map(list, fn name ->
        case Map.fetch(@legacy_coordinate, name) do
          {:ok, {coord, _}} -> coord
          :error -> "legacy.#{name}"
        end
      end)

    %Policy{
      allow: Enum.map(coordinates, &%{coordinate: &1, kinds: :any, actions: :any}),
      fidelity_min: :authoritative
    }
  end

  defp infer_kind(coordinate, action) do
    # Look at the registered ad's kinds and the action's idempotency in constraint
    # to pick a kind. Falls back to :action.
    alias LLMAgent.{ToolQuery, Tools.Discovery}

    case Discovery.find_one(ToolQuery.new(%{coordinate: coordinate})) do
      {:ok, ad} ->
        cond do
          :query in ad.kinds and get_in(ad.constraint, [:idempotency, action]) == :idempotent ->
            :query

          :action in ad.kinds ->
            :action

          true ->
            hd(ad.kinds)
        end

      _ ->
        :action
    end
  end

  defp invoke_via_dispatcher(:query, coord, action, args, policy) do
    case Dispatcher.query(coord, action, args, policy: policy) do
      {:ok, out, meta} -> {:ok, %{output: out, metadata: meta}}
      err -> normalize_dispatcher_error(err)
    end
  end

  defp invoke_via_dispatcher(:action, coord, action, args, policy) do
    case Dispatcher.act(coord, action, args, nil, policy: policy) do
      {:ok, ack, meta} -> {:ok, %{output: ack, metadata: meta}}
      err -> normalize_dispatcher_error(err)
    end
  end

  defp invoke_via_dispatcher(:compute, coord, action, args, policy) do
    case Dispatcher.compute(coord, action, args, policy: policy) do
      {:ok, value} -> {:ok, %{output: value, metadata: %{}}}
      err -> normalize_dispatcher_error(err)
    end
  end

  defp invoke_via_dispatcher(:stream, _coord, _action, _args, _policy) do
    {:error, ErrorStruct.new("stream_via_loop", "kind",
       "stream tools cannot be invoked through the prompt/response loop; use Dispatcher.subscribe/5 directly")}
  end

  defp invoke_via_dispatcher(:spawn, coord, action, args, policy) do
    # Treat the action arg as the spawn spec.
    case Dispatcher.spawn_child(coord, {action, args}, policy: policy) do
      {:ok, child_ref} -> {:ok, %{output: child_ref, metadata: %{}}}
      err -> normalize_dispatcher_error(err)
    end
  end

  defp normalize_dispatcher_error({:error, :forbidden, reason}),
    do: {:error, ErrorStruct.new("forbidden", "policy", "Policy denied: #{reason}",
                                 "Update allowed_tools or the agent's policy")}

  defp normalize_dispatcher_error({:error, %ErrorStruct{} = e}), do: {:error, e}

  defp normalize_dispatcher_error({:error, reason}),
    do: {:error, ErrorStruct.new("dispatch_failed", "tool", inspect(reason))}
```

Then update the call site at line 222 (inside `timed_dispatch/4`):

```elixir
    result =
      if tool_allowed?(tool, allowed) do
        dispatch_tool(tool, action, args, allowed)   # <-- add 4th arg
      else
        # ... existing error path ...
      end
```

(Adjust the existing `tool_allowed?/2` policy check — note that the legacy `tool_allowed?` permissive `:all` and list-based check is now redundant since Dispatcher enforces policy. Keep it as a fast pre-check OR remove it. Recommended: keep it for backward compatibility — the agent's `allowed_tools` semantics don't change for callers.)

- [ ] **Step 4: Run the new test — expect pass**

Run: `mix test test/llmagent/dispatch_via_substrate_test.exs 2>&1 | tail -20`
Expected: pass, including the telemetry assertion.

- [ ] **Step 5: Run full suite**

Run: `mix test 2>&1 | tail -10`
Expected: `0 failures`. If `test/agent_lifecycle_test.exs` regresses, the policy translation is too tight — check that `allowed_tools: :all` produces a policy that allows every substrate coordinate.

- [ ] **Step 6: Commit**

```bash
git add lib/LLMAgent.ex test/llmagent/dispatch_via_substrate_test.exs
git commit -m "Route agent dispatch through Tool.Dispatcher with %Policy{}

dispatch_tool/4 now translates legacy atom names to substrate
coordinates via a private map (the §7.6-step-9 catalog regen will
remove this map), builds a %Policy{} from the agent's allowed_tools
list using Policy.from_legacy_or_struct, and invokes via
Tool.Dispatcher.<kind>/4. Telemetry event [:llmagent, :tool, kind]
now fires on every tool call. perform/2 shims on each tool module
keep direct legacy callers working until §7.10 subtraction."
```

---

### Task 17: End-to-end validation against a real LAN llama (manual)

This is a one-time validation, not a regression test. It confirms the substrate now drives a real local-model session.

- [ ] **Step 1: Start the application**

```bash
mix phx.server     # if in agento, or `iex -S mix` in llmagent
```

- [ ] **Step 2: Verify mDNS-discovered llamas appear**

```elixir
LLMAgent.Tools.Discovery.find_all(
  LLMAgent.ToolQuery.new(%{coordinate: "generate.*"})
)
```

Expected: at least one ad per active LAN llama-server (skynet001 / skynet002 per the project memory).

- [ ] **Step 3: Verify all twelve builtin tools registered**

```elixir
for coord <- ["function.crypto", "resource.network", "resource.proc",
              "resource.fs.events", "resource.hardware.events",
              "resource.fs.file", "function.http", "function.systemd",
              "function.dbus", "function.coordination.tuplespace",
              "function.agent", "function.shell.bash"] do
  {coord, LLMAgent.Tools.Discovery.find_one(LLMAgent.ToolQuery.new(%{coordinate: coord}))}
end
```

Expected: every entry returns `{coord, {:ok, %ToolAd{}}}`.

- [ ] **Step 4: Drive a real agent prompt against a local llama**

In agento's chat UI, point an agent at skynet001 (or whichever LAN llama is currently up — discoverable via Step 2) and ask it to run `bash echo hello`. Watch the event log for:

- `agent.prompt`
- `agent.llm_response`
- `agent.tool_dispatch` with `tool: :bash`
- `[:llmagent, :tool, :action]` telemetry with `coordinate: "function.shell.bash"`
- `tool.bash` invocation event
- final `agent.message` with role `"assistant"`

If the telemetry event fires, the dispatch went through the substrate. Done.

- [ ] **Step 5: No commit** — this is operational verification.

---

## Self-Review (run after writing the plan)

Done inline. Items found and addressed:

1. **Spec coverage:** §7.2 (table reproduced in scope section), §7.3 (template provided once, referenced by each per-tool task), §7.4 (coexistence shim folded into Task 16 via `@legacy_coordinate` map), §7.5 (Task 16), §7.6 steps 2–8 (Tasks 2–13 + Task 14 + Task 16), §7.8 spirit (Task 15). §7.6 step 9 (catalog regen) and step 10 (subtraction) explicitly out of scope.

2. **Placeholder scan:** No "TBD" / "TODO" / "fill in details". Tasks 6 (Udev), 9 (Systemd), 10 (DBus), 11 (TupleSpace) each note inline that the kind decision requires reading the actual module first — that's investigative work, not a placeholder, and the per-tool task explicitly tells the engineer which file to read and what decision to make. Tasks 8 (Web), 12 (Agent) reuse Task 7's shape with named substitutions — code is reproduced enough that the engineer doesn't have to flip pages.

3. **Type consistency:** Coordinate strings match §7.2 throughout. Kind names match the canonical seven. Callback names (`compute/2`, `query/2`, `act/3`, `subscribe/3`, `unsubscribe/1`, `participate/3`, `leave/1`, `spawn_child/2`, etc.) match the kind module signatures verified in `lib/llmagent/tool/kinds/*.ex`. Return shapes match the kind-module @callback specs.

4. **Cross-cutting requirements** repeated at top so they don't need to be re-stated per task. Subagent dispatchers should excerpt the cross-cutting block into every subagent prompt.

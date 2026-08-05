# `:exec` binding adapter — design

**Date:** 2026-08-05
**Status:** approved, not yet implemented
**Component:** `LLMAgent.Tool.Adapter.Exec`

## Problem

`bin-watch.tcl` advertises 32 local commands into `LLMAgent.Tools.Discovery`, each
with a binding of the form:

```text
:binding [:exec {:argv ["/home/imsmith/bin/,slugify"] :interpreter "bash"}]
```

No adapter is registered for the `:exec` binding kind, so `Bindings.adapter_for(:exec)`
returns `{:error, :not_found}` and every discovered command is visible but not
invocable. This spec defines the adapter that closes that gap.

## The population being executed

This is not a generic subprocess runner. The tools it invokes have specific and
hostile properties, documented in `bin-watch.tcl`'s own header:

- Of the 20 comma-tools in `~/bin`, 11 have no argument parsing at all. They read
  `$1`/`$2` positionally. `,mkbooter --help` does not print help — it runs
  `dd if=--help | pv | sudo dd`.
- Every ad is `:fidelity :speculative`. The descriptions are derived from reading
  source, never from running anything. Nothing has been verified.
- Some tools are destructive or privileged (`,update` runs `sudo apt update`).

The design consequence: **there is no safe probing.** An agent cannot learn what a
tool does by invoking it. Every guard below exists because the usual fallback —
"try it and see" — destroys the machine.

## Decisions

### D1 — Arguments are a positional list

Calls pass `%{"args" => ["a", "b"]}`. The adapter appends the list to argv
verbatim.

The ads carry `:arity` and `:variadic` but no parameter names, because the
extractor reads `$1`/`$2` and there is nothing to name them from. A positional
list is exactly as expressive as what the ad actually knows. Named or numbered
schemes would invent structure the source does not contain.

### D2 — Refusal is based on the ad's own signals

The adapter refuses a call when the ad says the tool is dangerous or when the ad
says its own reading was incomplete. This is defense in depth beneath `Policy`,
not a replacement for it.

Rejected alternative: defer entirely to `Policy`. `Policy` is the right place for
authorization, but a single over-broad `allow` rule would then be the only thing
between an agent and `sudo apt update`. Given D1's population, one layer is not
enough.

Rejected alternative: a configured path allowlist. Maximally safe, but every newly
discovered tool needs a config edit, which defeats discovery.

### D3 — The dispatcher passes the resolved ad in `opts`

`Adapter` callbacks currently receive the binding payload and `opts`, never the ad.
D2 needs `ad.constraint.blast_radius` and `ad.meta.extraction`, both of which live
on the ad.

`dispatch/5` will put the ad into `opts` before calling `invoke`. Adapters that do
not care ignore it.

Rejected alternative: duplicate the signals into the binding payload. No core
change, but the same facts would live in two places on every ad and could
disagree. The `:meta` field exists precisely so this information has one home.

Rejected alternative: guard inside `Dispatcher`. That puts binding-kind-specific
knowledge into the generic dispatch path that all twelve builtins traverse.

### D4 — `act/5` only; the shim declares `:action`

`LLMAgent.Tool.Adapter` documents `query/4` as "Pure, idempotent, no side effects."
Running a local binary is I/O, and the claim that a given binary is side-effect
free is a static guess produced by `kinds_for` in `bin-watch.tcl`.

Labelling a guess as purity is the inversion `:fidelity` exists to prevent, and
`bin-watch.tcl`'s own comment says a false read-only is the dangerous direction.
So the adapter implements `act/5` only, and `kinds_for` returns `{action}`
unconditionally.

The read-only distinction is not lost. It survives in `blast_radius`, where it is
honestly labelled as an inference:

```text
,pdfpages  :kinds [:action]  :blast_radius {:scope :none}
,update    :kinds [:action]  :blast_radius {:scope :system :reversible false}
```

An agent selecting harmless tools filters on `blast_radius`, not on a purity claim.

## Interface

```elixir
LLMAgent.Tool.Dispatcher.act(
  "command.local.,slugify",
  "run",
  %{"args" => ["My File.txt"]},
  policy: policy
)
```

### Success

```elixir
{:ok, output, %{status: 0, truncated: false, duration_ms: 412}}
```

`output` is merged stdout and stderr.

### Failure

```elixir
{:error, {:exit_status, 2, output}}
{:error, {:timeout, 30_000, partial_output}}
{:error, {:refused, :blast_radius, :system}}
{:error, {:refused, :extraction, :incomplete}}
{:error, {:arity_mismatch, [expected: 1, got: 2]}}
{:error, {:unknown_action, "frobnicate"}}
{:error, {:spawn_failed, reason}}
```

## Guard order

Evaluated in this order; the first failure returns.

1. **Action name.** Must be `"run"`, the only action the shim emits. Otherwise
   `{:error, {:unknown_action, action}}`.
2. **Arity.** Checked against `ad.operational.actions["run"]`. When
   `variadic` is true, `arity` is a minimum and there is no upper bound. When
   false, the count must match exactly.
3. **Blast radius.** Refuse when `ad.constraint.blast_radius.scope` is `:system`
   or `:unknown`.
4. **Extraction.** Refuse when `ad.meta.extraction` is `:incomplete` or
   `:unsupported`. Both mean the `:requires` list is known to be short, so the ad
   understates what the tool touches.

Guards 3 and 4 are lifted per call:

```elixir
Dispatcher.act(coord, "run", args,
  exec_allow_blast_radius: [:system],
  exec_allow_extraction: [:incomplete])
```

`Policy.decide/4` still runs first and still denies everything by default. A
policy that permits a `:system` tool does not by itself lift guard 3 — the call
must opt in explicitly.

## Execution mechanics

**No shell, ever.** The argv head is the executable and caller args are appended
as separate argv entries. `;`, `|`, backticks and `$(…)` arrive as inert argument
text. There is no code path that builds a command string.

**Files without a shebang.** The shim flags these as `meta.no_shebang`; the kernel
cannot exec them directly. They run as `sh <path> <args...>` — still an argv exec
with the script as an argument, not a shell command string.

**Spawning.** `Port.open({:spawn_executable, path}, [:binary, :exit_status, :stderr_to_stdout, {:args, args}])`.
A port is used rather than `System.cmd/3` because `System.cmd/3` cannot be
interrupted, and an uninterruptible subprocess is how this repo spent a morning
watching `mix test` hang.

**Timeout.** Default 30_000 ms, overridable with `exec_timeout:`. On expiry the OS
process receives SIGTERM, then SIGKILL after a 200 ms grace period — the same
sequence and interval `PortAdapter` uses. `partial_output` in the timeout error is
whatever was captured before the kill, subject to the same 256 KB cap.

**Output.** stdout and stderr merged, capped at 256 KB. On overflow the output is
truncated and `truncated: true` appears in the metadata.

**Environment and working directory.** Inherited from the BEAM unless the caller
passes `exec_env:` or `exec_cd:`.

**Idempotency.** `act/5` receives `idempotency_key` and ignores it. These commands
have no idempotency mechanism; honouring the parameter would be a claim the
adapter cannot keep. Documented in the moduledoc rather than silently dropped.

## Changes outside the adapter

| File | Change |
| --- | --- |
| `lib/llmagent/tool/dispatcher.ex` | Put resolved ad into `opts` before `invoke` |
| `lib/llmagent/tool/bindings.ex` | Add `exec: LLMAgent.Tool.Adapter.Exec` to `@canonical` |
| `lib/llmagent/os_process.ex` | New. TERM/grace/KILL reaping |
| `lib/llmagent/discovery/port_adapter.ex` | Use `OSProcess` instead of its private `reap/1` |
| `priv/discovery/bin-watch.tcl` | `kinds_for` returns `{action}` unconditionally |

`LLMAgent.OSProcess` exists because `PortAdapter` grew the identical TERM/grace/KILL
sequence on 2026-08-05 while fixing the shim leak. The adapter needs the same
behaviour on timeout. Extracting it gives one implementation and one place to test
it.

## Testing

Fixture shell scripts written to a temp directory, following the pattern in
`test/tcl/bin_watch_test.tcl`.

- Clean exit returns `{:ok, output, meta}` with `status: 0`.
- Non-zero exit returns `{:error, {:exit_status, n, output}}`.
- stderr appears in the merged output.
- A fixture that sleeps past the timeout is killed, and the OS process is
  confirmed gone by reading `/proc/<pid>/stat` — matching the technique in
  `port_adapter_test.exs`, which distinguishes a zombie from a live process.
- Output over 256 KB is truncated and flagged.
- Arity mismatch is refused, both directions, with variadic honoured.
- Each refusal guard fires on a synthetic ad, and each lifts with its opt.
- **No-shell proof.** A fixture invoked with the literal argument
  `; touch /tmp/pwned` must receive it as one argv entry, and the file must not
  exist afterwards.
- Unknown action is refused.

## Risks

**Shared dispatch path.** Adding `:ad` to `opts` affects every dispatch, and
`Adapter.Module` forwards `opts` verbatim to `participate/3` and `spawn_child/2`.
Those builtins will begin receiving an extra key. Expected to be inert, but the
full suite is run against the change rather than assumed.

**Guards read fields that may be absent.** `meta` defaults to `%{}` and an ad from
another shim may omit `blast_radius`. A missing signal is treated as `:unknown` and
refused, not as permission.

**`:meta` is load-bearing now.** Guard 4 depends on `Wire` carrying `:meta`, which
it did not do before 2026-08-05. An older peer emitting ads through an unfixed
codec would present `meta: %{}` and silently lose guard 4. Guard 3 still applies.

## Out of scope

- `query/4`, `compute/4` and the other kind callbacks. See D4.
- Argument type coercion. Args are strings; the adapter does not interpret them.
- Streaming output. `act/5` returns on completion.
- Any change to `Policy`. Its existing `allow`, `fidelity_min` and
  `require_approval` machinery is sufficient and already runs ahead of the adapter.
- Populating `:confidence`, still dropped by `Wire` and recorded in `ISSUES.md`.

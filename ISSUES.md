# Issues

Tracked here until they migrate to a real issue tracker. Newest first.

## `strip_noise` loses sync on an unbalanced `$(` or quote

**Filed:** 2026-08-05
**Reported from:** writing regression tests for the arithmetic-stripping fix

### Symptom

A shell line containing an unbalanced command substitution or quote — the
literal `echo "$(("` will do — causes `strip_noise` to blank the remainder of
the file. Every requirement after that point disappears:

```text
#!/bin/bash
echo "$(("        <- scanner desyncs here
ffprobe -v error x
metaflac --list y  <- neither is reported
```

`:requires` comes back empty.

### Why it happens

`strip_noise` is a context stack. Inside double quotes, `$(` pushes a `normal`
context on the assumption it opens a command substitution that will close. When
it does not, the stack never unwinds, and the next `"` in the file is read as
opening a string rather than closing one. Everything to the following quote is
treated as string body and blanked.

### Why it matters

This fails in the dangerous direction. Every other known extraction error in
this shim adds a spurious requirement; this one silently removes real ones, and
the ad still claims `:extraction :complete`.

### What should change

Either bound the substitution context to the line it opened on, or detect an
unwound stack at end of input and mark the extraction `:incomplete` rather than
reporting a confident short list. The second is cheaper and honest.

Not to be confused with the arithmetic-stripping bug fixed on 2026-08-05 — that
one was in the regex pass and is covered by `arith-strip-does-not-eat-neighbours`
in `test/tcl/bin_watch_test.tcl`. This defect is in the scanner underneath it.

---

## `Tools.Web` tests depend on a live third-party service

**Filed:** 2026-08-05
**Reported from:** full-suite run while fixing the discovery defects

### Symptom

Four tests in `test/tools/web_test.exs` fail whenever `httpbin.org` is
unreachable or rate-limiting:

```text
** (MatchError) no match of right hand side value:
    {:ok, %{output: "<html>...503 Service Temporarily Unavailable...",
            metadata: %{status: 503, url: "https://httpbin.org/get"}}}
```

Observed 2026-08-05 with httpbin returning 503 for every request.

### Why it matters

The suite cannot distinguish "the HTTP tool broke" from "someone else's server
is down", and it does not pass offline. `bypass` is already a dependency and is
used elsewhere in this repo.

### What should change

Point these four at a local `bypass` endpoint, as the other HTTP-touching tests
do. Nothing about the assertions requires a real remote host.

---

## `PortAdapter` does not reap its port children on VM exit

**Filed:** 2026-08-04
**Fixed:** 2026-08-05
**Reported from:** enabling the `bin_watch` discovery adapter

### Symptom

Every `mix run` leaves one orphaned `tclsh` process per configured discovery
adapter. Observed repeatedly during a single session:

```text
$ ps -eo pid,etimes,args | grep priv/discovery
2801487  4474  /usr/bin/tclsh .../priv/discovery/avahi-llama.tcl
2835952   911  /usr/bin/tclsh .../priv/discovery/avahi-llama.tcl
2841885   320  /usr/bin/tclsh .../priv/discovery/avahi-llama.tcl
```

Those three accumulated from three separate `mix run` invocations. The BEAM
exited; the port programs did not. They keep running, keep scanning, and keep
writing to a stdout nobody reads — which is where the familiar

```text
error writing "stdout": broken pipe
    while executing "puts "{:event :register :ad $ad}""
```

noise in the console comes from. It is not a shim bug; it is a leaked child
discovering its reader is gone.

With `bin_watch` now enabled alongside `avahi_llama`, the leak rate doubled to
two processes per run.

### Why it happens

`Port.open/2` with `:spawn_executable` does not kill the external program when
the port closes unless the program itself notices EOF on stdin and exits.
`avahi-llama.tcl` blocks on `gets` from a pipe it opened itself, and
`bin-watch.tcl` loops on `after`; neither watches stdin. When the owning
process dies the port closes, but the OS process survives.

### What should change

Two halves, and both are needed:

1. **Adapter side.** `PortAdapter` should trap exits and, on terminate, send an
   explicit kill. The portable form is to spawn under a supervising wrapper, or
   to record the OS pid (`Port.info(port, :os_pid)`) and `System.cmd("kill", ...)`
   it in `terminate/2`. Relying on port closure alone is not sufficient.
2. **Shim side.** A shim should exit when stdin closes. For a Tcl shim that
   means making stdin readable and installing a handler:

   ```tcl
   fconfigure stdin -blocking 0
   fileevent stdin readable { if {[eof stdin]} exit }
   ```

   `bin-watch.tcl` cannot do this today because its main loop is a blocking
   `after`, not an event loop. It would need `vwait` with a timer instead.

### Resolution — 2026-08-05

Both halves are in, plus a third that the original writeup missed.

- **Adapter.** `PortAdapter` records `Port.info(port, :os_pid)` at open time and
  `terminate/2` signals it — SIGTERM, 200ms grace, then SIGKILL. Covered by
  `test "kills the shim's OS process when the adapter terminates"`, which uses
  `sleep` as a shim that ignores stdin.
- **Shims.** `bin-watch.tcl` moved from a blocking `after` to an `after`-driven
  timer under `vwait`, and both it and `avahi-llama.tcl` now exit on stdin EOF.
  `avahi-llama.tcl`'s read loop became a `fileevent` so one event loop can watch
  both channels.
- **Grandchildren.** `avahi-llama.tcl` opens `|stdbuf -oL avahi-browse` as a
  command pipeline, and Tcl does not signal pipeline children on exit — so every
  run left an `avahi-browse` behind even once the shim exited correctly. 25 had
  accumulated on this host. It now kills `[pid $chan]` on the way out.

The severity was understated. Because the leaked shim holds the *inherited
stdout pipe* open, nothing reading that pipe ever sees EOF: `mix test` appeared
to hang indefinitely with no output, having actually finished. That is the same
bug, not a separate one.

`terminate/2` does not run on a brutal VM halt, which is why the shim-side EOF
watch is required rather than merely tidy.

---

## `Wire` drops the `:meta` field, losing every honesty signal

**Filed:** 2026-08-04
**Fixed:** 2026-08-05
**Reported from:** `bin-watch.tcl` conformance testing

### Symptom

`bin-watch.tcl` emits ads carrying a populated `:meta` map:

```text
:meta {:extraction :incomplete :language "bash" :no_shebang true}
```

`Wire.decode/1` accepts the line, produces a valid `%LLMAgent.ToolAd{}` — and
the struct comes back with `meta: %{}`.

### Why it matters

`:meta` is where this shim puts everything it is *unsure* about:

- `:extraction :incomplete` — `eval` or `$CMD` dispatch defeated static reading,
  so the `:requires` list is known to be short
- `:extraction :unsupported` — the file is in a language with no extractor, so
  `:requires` is empty for lack of knowledge, not lack of dependencies
- `:no_shebang true` — the tool has no shebang and runs under whatever shell
  invokes it, which is a genuine portability defect

A consumer that cannot see these treats a deliberately-empty `:requires` as a
confident "this tool has no dependencies." That inverts the meaning of the
field, and it is exactly the failure mode `:fidelity` exists to prevent.

### What should change

Carry `:meta` through `Wire.decode/1` into `ToolAd.new/1`. The field already
exists on the struct with a `%{}` default, so this is a codec gap rather than a
schema change.

### Resolution — 2026-08-05

`to_ad/1` reads `:meta` with a `%{}` fallback so shims that omit it still decode,
and `ad_to_map/1` writes it so the field survives a round trip. `normalise_value/1`
gained a list clause — EDN lists decode to plain Elixir lists, whose elements
still need walking. Three tests in `wire_test.exs` cover carry-through, the
omitted-field default, and a round trip with nested collections.

Still dropped by the codec: **`:confidence`**. Same class of gap — it is on the
struct, it is meaningful for `:speculative` ads, and `Wire` neither reads nor
writes it. Not fixed here because no shim populates it yet.

---

## `bin-watch.tcl` reports arity 0 for tools that quote their positionals

**Filed:** 2026-08-04
**Fixed:** 2026-08-05
**Reported from:** self-review after the comment/string stripping fix

### Symptom

```text
,cleantags   :actions {"run" {:arity 0 :variadic false}}   # actually takes 1
,animated?   :actions {"run" {:arity 0 :variadic false}}   # actually takes 1
```

but

```text
,create-pdf-record  :arity 1   # correct
```

### Why it happens

Arity is derived from `$1`/`$2` references in the *stripped* code, and stripping
removes double-quoted string contents. `"$1"` — the correct, quoting-safe way to
reference an argument in shell — is therefore invisible. Only the unquoted `$1`
form survives, which is the form careful scripts avoid.

This is a regression introduced by the comment/string stripping fix, not an
original defect.

### What should change

Positional parameters must be read from a pass that removes **comments and
heredocs only**, keeping string contents. Requirement extraction still needs the
fully-stripped code; the two scans want different inputs. Split them.

### Resolution — 2026-08-05

`strip_noise` takes a `keep_strings` flag; `interrogate` runs it twice and reads
positionals from `argcode` while requirements still come from `code`.

One deviation from the prescription above: **single-quoted contents stay
blanked** in both passes. `'$1'` does not expand in shell, so keeping it would
invent positionals the script never receives.

The defect was wider than filed. `:variadic` is derived from the same scan, and
`"$@"` is quoted for the same reason `"$1"` is — so *all 32* ads reported
`:variadic false`. Two now correctly report true, and the arity distribution
moved from 25 zeros to 19.

---

## `bin-watch.tcl` residual token noise

**Filed:** 2026-08-04
**Fixed:** 2026-08-05
**Reported from:** live registry inspection

### Symptom

Six of 32 ads carry tokens that are not commands:

```text
,animated?                   :missing ["byte"]
,mkpl                        :missing ["OPTIND-1", "duration", "metaflac"]
getter                       :missing ["count", "counter"]
,gen_cmd_registry            :missing ["--"]
```

`metaflac` is a real missing dependency. `byte`, `count`, `counter`,
`OPTIND-1` and `--` are not.

### Why it happens

Three distinct leaks:

- `$((OPTIND-1))` — arithmetic expansion. `(` is normalised to a segment break,
  so `OPTIND-1` lands in command position.
- `exec man -w -- $cmd` — `--` is an end-of-options marker, not a command, and
  the Tcl `exec` extractor takes the first token after `exec` plus flags.
- `local byte=$(...)` and similar — an assignment split across a command
  substitution boundary leaves a bare fragment.

All are safe-direction errors: they add spurious requirements rather than hiding
real ones. A tool is reported as needing something it does not, never the
reverse.

### What should change

- Skip arithmetic expansion `$(( ... ))` entirely rather than treating `(` as a
  separator inside it.
- Filter `--` and tokens beginning with `-` from the Tcl `exec` extractor.
- Treat `NAME=` as an assignment prefix even when the value was consumed by a
  substitution split.

### Resolution — 2026-08-05

All six tokens are gone; `:missing` now carries only `yt`, `metaflac` and
`dns-sd`, which are genuinely absent from this host. Two of the three diagnoses
above were wrong, so the fixes differ from what was prescribed:

- **Arithmetic — confirmed, and the cause of four tokens, not one.** `byte`,
  `count` and `counter` were attributed to assignment-splitting; they are all
  `$(( ))` and `(( ))` operands, exactly like `OPTIND-1`. `strip_noise` now
  consumes `$(( ... ))` with paren-depth tracking, because only the scanner
  knows whether a `$((` sits inside quotes — `"$((count + 1))"` was otherwise
  left as the half-stripped fragment `(count + 1`. A line-anchored regex pass
  catches the bare `(( ))` command form.
- **`--` does not come from the `exec` extractor.** That regex cannot capture
  it — the capture class requires a leading alphanumeric. It comes from the
  explicit dependency-check scan, whose class *does* include `-`, matching
  `type -t -- "$c"` in `,gen_cmd_registry`. Tokens starting with `-` are now
  filtered there.
- **There is no assignment-splitting leak.** `duration` came from `${duration}`:
  `{` and `}` normalise to segment breaks, severing the name from its `$` and
  stranding it in command position. Brace parameter expansions are now stripped.

Both regex passes are `-line` anchored. An unanchored `.*?` reaches across
newlines, so an unpaired `$((` would delete every command up to the next `))` —
under-reporting requirements, which is the one direction this shim must not
fail in. See the separate `strip_noise` desync entry for a case that still does.

Covered by 18 tests in `test/tcl/bin_watch_test.tcl`; the shim is now sourceable
(its driver is behind an `argv0` guard) so its procs can be tested directly.

---

## mDNS-discovered endpoints are write-only when `llmagent` runs standalone

**Filed:** 2026-08-04
**Reported from:** as-built architecture review

### Symptom

The discovery path is fully wired and runs in production:
`priv/discovery/avahi-llama.tcl` → `PortAdapter` → `Wire` →
`Tools.Discovery.register/1`. Ads with coordinate `compute.llm.chat` are
registered correctly.

Nothing in `llmagent`'s own `lib/` ever consumes one.

- `LLMAgent.ex`'s dispatch helpers branch on `query`/`act`/`compute`/`spawn`.
  There is no `:generate` branch.
- The agent's LLM call uses `llm_client` with the `api_host` from its start
  opts, not `Dispatcher.generate` against a discovered ad.
- `grep compute.llm.chat` across `lib/` hits the shim and three test files.

The only production consumer is in the *other* repo:
`AgentoWeb.Discovery.Endpoints` projects the ads into agento's new-agent
dropdown.

### Consequence

Standalone `llmagent` advertises endpoints it never dials. The feature is
end-to-end functional only when agento is the host — which is also the only
place `:discovery_adapters` is configured with `Application.app_dir/2` paths
that survive being a dependency.

### What should change

Either add a `:generate` dispatch branch so standalone llmagent can use what it
discovers, or document that discovery is a service llmagent provides to hosts
rather than something it consumes.

### Partial resolution — 2026-08-05

The `:exec` binding adapter (`LLMAgent.Tool.Adapter.Exec`, registered in
`LLMAgent.Tool.Bindings`) makes discovered `command.local.*` ads from
`priv/discovery/bin-watch.tcl` consumable through
`LLMAgent.Tool.Dispatcher.act/4`. The original complaint — "advertises
endpoints it never dials" — no longer holds for that half of discovery: a
locally discovered command is now dispatchable end to end, subject to
`LLMAgent.Tool.Policy` (deny-by-default) and the adapter's own refusal guards.

**Not resolved:** the mDNS `compute.llm.chat` ads are untouched. There is
still no `:generate` dispatch branch in `LLMAgent.ex`, and the agent's LLM
call still goes through `llm_client`/`api_host` rather than
`Dispatcher.generate` against a discovered ad. The original symptom and
consequence stand as written for that ad kind — this entry stays open.

---

## Two of the seven canonical kinds are declared by nothing

**Filed:** 2026-08-04
**Reported from:** as-built architecture review

### Symptom

`Kinds.init_registry/0` seeds seven canonical kinds. The twelve native tools
cover five: `query`, `action`, `compute`, `stream`, `spawn`.

- **`:coordinate`** is declared by no tool at all — including
  `LLMAgent.Tools.TupleSpace`, whose own legacy coordinate is
  `function.coordination.tuplespace` and which declares `Query` + `Action`.
- **`:generate`** is declared by no native tool; it exists solely for discovered
  mDNS ads.

Separately, **`:stream` is unreachable from a prompt**. `llmagent.ex:374`
refuses it outright:

> stream tools cannot be invoked through the prompt/response loop; use
> `Dispatcher.subscribe/5` directly

`Tools.Inotify` is the only `:stream` tool, and nothing in `lib/` makes that
direct call. It is reachable only from tests.

### What should change

Decide whether these kinds are aspirational or live. If live, `TupleSpace`
should declare `:coordinate` and something in `lib/` should subscribe to a
`:stream` tool. If aspirational, say so in `Kinds`' moduledoc so the seven-kind
registry is not read as seven working kinds.

---

## Documentation drift in `README.md` and `arch/`

**Filed:** 2026-08-04
**Reported from:** as-built architecture review

### Symptom

- README's ASCII diagram says **"10 Tools"**; `Builtins.register_all/0`
  registers **12**.
- README's supervision tree omits `LLMAgent.Tools.Discovery` and
  `LLMAgent.Discovery.AdapterSupervisor`, both started by `Application.start/2`.
- `arch/analysis-design-vs-implementation-vs-openclaw.md` (dated 2026-02-15)
  lists tuple space, the `Memory` behaviour, the `LLMClient` behaviour
  abstraction, and tool access control as "not implemented". All four exist:
  `lib/llmagent/tuple_space/`, `LLMAgent.Memory` + `Memory.ETS`,
  `LLMAgent.LLMClient` + `LLMClient.OpenAI`, `LLMAgent.Tool.Policy`.
- The `arch/` "remaining gaps" note describes per-tool migration to `ad/0` as
  in progress. All 12 builtins implement `ad/0` today — `register_all/0` calls
  `mod.ad()` on every one, so a non-migrated tool would crash boot. What has
  *not* happened is retirement of the legacy path: all 12 still carry the
  deprecated `perform/2`, the legacy `LLMAgent.Tools` persistent_term registry
  is still live and is still what agento reads via `Tools.all/0`, and
  `LLMAgent.ex` still holds the `@legacy_coordinate` map.

### What should change

The dated analysis document is defensible as a historical record — it carries
its date. The README counts are not. Fix the tool count and the supervision
tree, and reword the migration note to say "registry retirement" rather than
"migrations", since `ad/0` adoption is complete.

### Partial resolution — 2026-08-05

README's diagram, tools table, supervision tree, and test-count line now say
12, and the supervision tree lists `LLMAgent.Tools.Discovery` and
`LLMAgent.Discovery.AdapterSupervisor`. Both README symptoms above are fixed.

**Not resolved:** `arch/analysis-design-vs-implementation-vs-openclaw.md` was
not touched — this task's scope was `README.md` and `ISSUES.md` only. The
stale "not implemented" claims and the "migrations in progress" wording in
that file still stand and still need the rewording described above.

# LLMAgent — Elixir Agent Framework

## Sprint Context

Active sprint through Feb 28, 2026. Full plan: `/home/imsmith/Documents/remote.vault.001/src/099 Katachora/SPRINT-2026-02.md`

LLMAgent is Phase 3 (Feb 23-28). Read the sprint plan for day-by-day tasks.

## What LLMAgent Is

A GenServer-based framework for building autonomous AI agents that invoke system tools in a controlled manner. The agent talks to an LLM API, parses tool-call JSON from responses, dispatches to tool modules, formats results, and loops back to the LLM.

## Current State (as of Feb 12, 2026)

**BROKEN — does not compile.** Last commit changed `lib/LLMAgent.ex` to `require Comn` but Comn is not in mix.exs dependencies.

### What Works (when it compiled)
- **Bash tool** — tested, proper error handling
- **Web tool** — GET/POST with headers/params, tested
- **Crypto tool** — full ed25519 & ecdsa, key generation, signing/verification
- **EventBus** — Registry-based pub/sub, tested
- **EventLog** — in-memory immutable log with query API
- **RequireBinary utility** — checks system binaries exist

### What's Partial
- File, Net, Proc, DBus, Systemd, Udev tools — work but return raw text, inconsistent error handling

### What's Broken/Missing
- **Comn dependency** — not in mix.exs, compilation fails
- **Application startup** — requires wg, ssh-keygen, gpg or crashes
- **Inotify tool** — perform/2 returns :not_implemented (Watcher GenServer exists but unused)
- **Agent lifecycle tests** — stub test checks nonexistent hello/0 function
- **Event wiring** — emit_event exists but tools don't emit events

## Depends On

**Comn** at `~/github/comn` — must be added as path dependency:
```elixir
{:comn, path: "../comn"}
```

Comn must be at v0.2.0 (sprint Phase 1) before LLMAgent work begins.

## Sprint Goal for LLMAgent

**Exit criteria:**
```
mix compile   -> 0 errors (with Comn dependency)
mix test      -> all pass
manual test   -> agent prompts, dispatches tool, returns result
git tag       -> v0.2.0
README        -> documents architecture, tools, usage
```

## Key Decisions This Sprint

1. **Comn integration**: Add as path dependency, alias Comn.Errors.ErrorStruct and Comn.Events throughout
2. **Startup requirements**: Make wg/ssh-keygen/gpg optional (warn, don't crash)
3. **Tool output format**: Standardize ALL tools to `{:ok, %{output: term(), metadata: map()}} | {:error, %ErrorStruct{}}`
4. **Inotify**: Implement or delete — no stubs
5. **Events**: All tool invocations emit events; agent emits prompt/response/error events

## Architecture

```
prompt(agent, content)
  -> GenServer.call
    -> append to history
    -> async Task: call LLM API
      -> parse JSON response
        -> tool_call? dispatch_tool(tool, action, args)
          -> Tools.tool() -> module.perform(action, args)
          -> format result -> append to history -> loop
        -> not tool_call? append assistant message -> done
```

## Available Tools

| Tool | Module | Status | Actions |
|---|---|---|---|
| bash | Tools.Bash | Working | exec |
| web | Tools.Web | Working | get, post |
| file | Tools.File | Basic | read, write, delete |
| crypto | Tools.Crypto | Working | sha256, hmac, generate_key, generate_keypair, sign, verify |
| dbus | Tools.DBus | Basic | list, introspect, call |
| systemd | Tools.Systemd | Basic | status, start, stop, restart, list |
| proc | Tools.Proc | Basic | list, info |
| net | Tools.Net | Basic | list_interfaces, ping, resolve |
| udev | Tools.Udev | Basic | list, info, usb, pci |
| inotify | Tools.Inotify | Stubbed | (decide: implement or remove) |

## Dependencies

```elixir
# mix.exs
req ~> 0.5.0           # HTTP client
jason ~> 1.4           # JSON
b58 ~> 1.0             # Base58 encoding
mix_test_watch ~> 1.1  # dev-only TDD
# MISSING — add this sprint:
comn (path: "../comn")
```

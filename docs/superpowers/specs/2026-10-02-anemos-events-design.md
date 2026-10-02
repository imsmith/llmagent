# The substrate as Anemos's event source

**Date:** 2026-10-02 · **Branch:** `anemos-events` · item 3 of the Anemos program

## Problem

A rule begins with `when EVENT`, and nothing on this machine produces one.
The substrate already sees what happens — every `LLMAgent.Events.emit/4`
(inotify, the hub, agents, tuple spaces, MCP) and every tool that appears or
leaves `Discovery` — and a rule cannot hear any of it. In the other
direction, `emit ... to channel(path)` reaches the default connector, which
logs it.

"Every emit is a message. Every when is a subscription."

## Design

Two more children of the `LLMAgent.Anemos` attachment, which is now a
supervisor over `Tools` (item 2), `Events`, and a connector.

### In: the bus, dispatched

`LLMAgent.Events.emit/4` now also broadcasts on the topic `"*"`.
`LLMAgent.Anemos.Events` subscribes to it and dispatches every event into
the runtime:

| substrate | Anemos event | context path | facts |
| --- | --- | --- | --- |
| topic `tool.inotify.event` | `TOOL_INOTIFY_EVENT` | `tool.inotify.event` | the data, plus `?topic ?type ?source ?id` |
| topic `hub.request` | `HUB_REQUEST` | `hub.request` | likewise |
| ad registered / updated / gone | `TOOL_ADDED` / `TOOL_UPDATED` / `TOOL_REMOVED` | the coordinate | `?id ?coordinate` |

The name is the topic, uppercased, with every run of non-alphanumerics an
underscore. The topic as context path is what makes
`context "tool.inotify" { when TOOL_INOTIFY_EVENT ... }` work: the filter is
segment-aware.

### Out: emit, published

`LLMAgent.Anemos.Channel` is connected as the runtime's channel connector.
`emit [EVENT::ip.addr.changed :iface "eth0"] to channel(system.config.network)`
becomes an event on topic `system.config.network` with data
`%{payload: %{"event" => "ip.addr.changed", "iface" => "eth0"}, rule: "...", label: ...}`.

`EVENT` is registered in the runtime by the attachment: its verb is the
event's name, its arguments key-value pairs, and it does nothing but answer
them. The README's idiom works as written.

### Loops have a ceiling

A runtime's own emits carry `source: {LLMAgent.Anemos.Channel, runtime}`
and are not dispatched back into that runtime. Another runtime's are
events like any other.

That is not enough on its own, and the review proved it: a rule that calls
a tool which emits — the tuple space, inotify after a `write`, any agent —
is a loop with no call depth to bound it. So causation is counted. Every
event carries a correlation id (its own id if it has none); the rules run
under it in the ambient `Comn` context, a tool is called with that context
set, and what it emits inherits the id. Past `:hop_limit` events (default
64) on one correlation, the rest are dropped and the log says so once. Two
runtimes feeding each other count the same chain and stop the same way.

### What the review added

- Payloads of any shape are taken: a struct, a map with tuple keys, a tuple
  type. The events process does not die on data.
- An event no rule or condition subscribes to is not dispatched: no trace
  entry, no persist, no condition round-trip. One `explain` call, which is
  cheaper than the dispatch it saves.
- A dispatch that does not answer within `:dispatch_timeout_ms` is logged
  as such, and the log says the rules may still run.
- The tools process binds `EVENT`, the connector and every tool name at
  start, and dies with the runtime's supervisor, so a runtime that comes
  back empty is bound again. Start the attachment after the runtime, under
  the same supervisor.
- A rule can emit on any topic, and that goes into the event log and the
  durable log like any event. The source says who said it; a consumer that
  acts on a topic has to read it. Not narrowed here.

## Rulings

1. **Events are dispatched from their own process**, serially, in arrival
   order. The tools process must stay free to answer a verb mid-dispatch.
2. **Topic as name, topic as context, data as facts.** No per-topic
   translation table; a rule author reads the topic off the log.
3. **Top-level keys only** become facts. A nested map is a value a rule can
   hand to a verb.
4. **A dispatch the runtime cannot take is logged and dropped.** The event
   process does not die with the event.
5. **`events: false` and `connect: false`** opt out of either direction.

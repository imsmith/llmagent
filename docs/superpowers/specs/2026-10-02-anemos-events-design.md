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

### No loop

A runtime's own emits carry `source: LLMAgent.Anemos.Channel` and are not
dispatched back into any runtime. Within a runtime, `emit ... as :label`
chains rules, under the dispatcher's recursion ceiling. Across the bus
there is no ceiling, so there is no feedback.

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

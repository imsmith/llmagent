# MCP Client Integration — Design Spec

**Date:** 2026-04-10
**Status:** Approved
**Scope:** Consume external MCP servers as tools from LLMAgent agents

## Goal

Let LLMAgent agents call tools exposed by external MCP servers. An agent should be able to use an MCP tool identically to a native tool — same dispatch path, same result format, same event emission. This addresses the "extension model" gap: adding tools without modifying LLMAgent source.

## Scope

**In scope:**
- MCP client protocol: `initialize` handshake, `tools/list` discovery, `tools/call` invocation
- HTTP (Streamable HTTP) transport — first implementation
- Transport behaviour abstracting HTTP/stdio for future expansion
- Runtime API for connecting/disconnecting MCP servers
- Automatic tool registration into the existing `Tools` persistent_term registry
- Tool proxy that adapts MCP tools to the `LLMAgent.Tool` behaviour

**Not in scope:**
- MCP resources, prompts, sampling, logging, roots, notifications
- Stdio transport (future, behind the same behaviour)
- User-facing configuration file (future)
- Changes to the existing `Tool` behaviour or `dispatch_tool/3`

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Transport | HTTP first, behaviour abstraction for stdio later | No local MCP servers to test against currently |
| Supervision | GenServer per connection + DynamicSupervisor + Registry | Matches existing AgentSupervisor pattern; independent fault isolation |
| Tool naming | Namespaced atoms — `:{server}_{tool}` | Flat namespace, no collisions, obvious provenance in logs |
| Description format | Free-text generated from MCP inputSchema | No changes to existing tool interface or agent loop |
| Proxy dispatch | Single ToolProxy module + persistent_term side map | Avoids generating modules; no changes to Tools.register/2 |
| MCP capabilities | Tools only | Minimum viable; resources/notifications have no consumer yet |

## Architecture

### Supervision Tree (additions)

```
LLMAgent.Supervisor (existing, one_for_one)
├── ... existing children ...
├── Registry (LLMAgent.MCP.Registry, keys: :unique)
├── DynamicSupervisor (LLMAgent.MCP.ConnectionSupervisor)
│   ├── LLMAgent.MCP.Connection (:github)
│   ├── LLMAgent.MCP.Connection (:slack)
│   └── ...
```

### Module Structure

```
lib/
  llmagent/
    mcp/
      mcp.ex                   # Facade: connect/2, disconnect/1, list_connections/0, tools_for/1
      connection.ex            # GenServer per MCP server
      connection_supervisor.ex # DynamicSupervisor (if needed beyond inline config)
      tool_proxy.ex            # Implements Tool behaviour, routes to Connection
      transport.ex             # Behaviour: start/1, send_request/2, close/1
      transport/
        http.ex                # HTTP (Streamable HTTP) implementation via Req
```

## Transport Behaviour

```elixir
defmodule LLMAgent.MCP.Transport do
  @type request :: %{method: String.t(), params: map(), id: integer()}
  @type response :: {:ok, map()} | {:error, term()}

  @callback start(opts :: keyword()) :: {:ok, state :: term()} | {:error, term()}
  @callback send_request(state :: term(), request()) :: {response(), new_state :: term()}
  @callback close(state :: term()) :: :ok
end
```

### HTTP Implementation

- `start/1` — stores base URL and auth headers. No persistent connection.
- `send_request/2` — wraps as JSON-RPC 2.0 (`{"jsonrpc": "2.0", "method": ..., "params": ..., "id": ...}`), POSTs via `Req`, parses response envelope (`result` or `error`).
- `close/1` — no-op for HTTP.

## Connection GenServer

### State

```elixir
%{
  name: :github,
  transport: LLMAgent.MCP.Transport.HTTP,
  transport_state: %{url: "https://...", headers: [...]},
  server_capabilities: %{},
  protocol_version: "2025-03-26",
  tools: [:github_create_issue, :github_list_repos]
}
```

### Lifecycle

1. **init/1** — Create transport via `Transport.start/1`. Send `initialize` request with client info and capabilities. Receive server capabilities and protocol version. Call `tools/list`. For each tool: build namespaced atom, generate description, update persistent_term side map, register `ToolProxy` in `Tools` registry. Store tool list in state for cleanup.

2. **handle_call({:call_tool, tool_name, args})** — Send `tools/call` via transport. MCP returns content blocks (text, image, resource). Concatenate text blocks into a single string output. Return `{:ok, %{output: text, metadata: %{mcp_server: name, mcp_tool: tool_name}}}`. On MCP error, return `{:error, ErrorStruct}`.

3. **terminate/1** — Unregister each tool from `Tools` registry. Remove entries from the `:llmagent_mcp_tool_map` persistent_term. Call `Transport.close/1`.

### Error Handling

- `initialize` failure in `init/1` → `{:stop, reason}`. No tools registered, DynamicSupervisor handles it.
- `tools/call` failure at runtime → `{:error, ErrorStruct}`. Same as native tool failure. Agent loop handles it.
- Connection process crash → supervisor restarts. `init/1` re-runs discovery, re-registers tools. Brief window where tools return `:not_found`, which the agent already handles.

## Tool Discovery & Registration

### MCP tools/list response (example)

```json
{
  "tools": [
    {
      "name": "create_issue",
      "description": "Create a GitHub issue",
      "inputSchema": {
        "type": "object",
        "properties": {
          "repo": {"type": "string"},
          "title": {"type": "string"},
          "body": {"type": "string"}
        },
        "required": ["repo", "title"]
      }
    }
  ]
}
```

### Registration steps (per tool)

1. Build atom: `:"github_create_issue"`
2. Generate free-text description from schema:
   ```
   create_issue: Create a GitHub issue

   Args:
     - repo (string, required)
     - title (string, required)
     - body (string, optional)
   ```
3. Update persistent_term `:llmagent_mcp_tool_map`:
   ```elixir
   %{github_create_issue: %{connection: :github, tool: "create_issue", description: "..."}}
   ```
4. Register in Tools: `Tools.register(:github_create_issue, LLMAgent.MCP.ToolProxy)`

### ToolProxy dispatch flow

```
Agent parses: {"tool": "github_create_issue", "action": "call", "args": {...}}
  → Tools.get(:github_create_issue) → {:ok, LLMAgent.MCP.ToolProxy}
  → ToolProxy.perform("call", args)
  → reads :github_create_issue from :llmagent_mcp_tool_map
  → finds %{connection: :github, tool: "create_issue"}
  → GenServer.call(connection_pid, {:call_tool, "create_issue", args})
  → Connection sends tools/call via transport
  → returns {:ok, %{output: ..., metadata: ...}}
```

ToolProxy ignores the action string — MCP tools have only one action (call). Args pass through directly.

### ToolProxy.describe/0

Since `describe/0` takes no arguments and the proxy serves all MCP tools, it returns a static string: `"MCP tool proxy — see individual tool descriptions via LLMAgent.MCP.tool_description/1"`. This satisfies the behaviour contract but isn't used for system prompt construction.

For system prompts, the agent's prompt builder should call `LLMAgent.MCP.tool_descriptions/0` which iterates the `:llmagent_mcp_tool_map` and returns the per-tool free-text descriptions. This is the same pattern as native tools — the agent already collects descriptions from all registered tools for the system prompt.

## Public API

```elixir
# Connect to an MCP server
LLMAgent.MCP.connect(:github,
  url: "https://api.github.com/mcp",
  headers: [{"authorization", "Bearer ..."}]
)
# → {:ok, pid} | {:error, reason}

# Disconnect
LLMAgent.MCP.disconnect(:github)
# → :ok

# List active connections
LLMAgent.MCP.list_connections()
# → [{:github, pid, %{tools: [...], protocol_version: "2025-03-26"}}]

# List tools for a specific connection
LLMAgent.MCP.tools_for(:github)
# → [:github_create_issue, :github_list_repos]
```

`LLMAgent.MCP` is a facade module with no process. It delegates to `ConnectionSupervisor` for start/stop and `MCP.Registry` for lookups.

## Dependencies

No new dependencies. `Req` (already in deps) handles HTTP. `Jason` (already in deps) handles JSON-RPC serialization. `Comn.Errors.ErrorStruct` for error returns.

## Event Emission

MCP tool calls flow through the existing `timed_dispatch/3` in the agent, so they automatically get:
- `tool.{server}_{tool}` events with `:invocation` type
- Duration tracking
- Context enrichment from `Comn.Contexts`

The Connection GenServer can additionally emit:
- `mcp.connected` — when initialize handshake completes
- `mcp.disconnected` — on terminate
- `mcp.tools_discovered` — after tools/list, with count and tool names

## Testing Strategy

- **Transport.HTTP** — mock HTTP responses with `Req.Test` adapter. Test JSON-RPC envelope construction, response parsing, error handling.
- **Connection** — test init lifecycle (handshake → discovery → registration), tool call dispatch, terminate cleanup. Use a mock transport module.
- **ToolProxy** — test perform/2 routing through the side map to a mock connection.
- **Integration** — start a Connection with mock transport, verify tools appear in `Tools.all()`, call a tool through the normal agent dispatch path, verify it unregisters on disconnect.

# LLMAgent

A GenServer-based AI agent framework for Elixir. LLMAgent connects to any OpenAI-compatible API, dispatches tool calls to local system tools, and records structured events for every action.

Built for Linux system administration — the default toolset gives an LLM hands-on access to bash, files, processes, networking, systemd, D-Bus, udev, inotify, and cryptographic operations.

**License:** AGPL-3.0

## Architecture

```
User Prompt
    │
    ▼
┌──────────┐     ┌─────────────┐     ┌──────────────┐
│ LLMAgent │────▶│  LLM API    │────▶│ Tool Dispatch│
│(GenServer)│◀───│ (OpenAI fmt)│     │              │
└──────────┘     └─────────────┘     └──────┬───────┘
    │                                       │
    ▼                                       ▼
┌──────────┐                         ┌──────────────┐
│ EventLog │◀────────────────────────│  10 Tools    │
│ EventBus │                         └──────────────┘
│DurableLog│
└──────────┘
```

The agent runs as a GenServer. When it receives a prompt, it:

1. Sets a `Comn.Contexts` context with `request_id`, `trace_id`, and role metadata
2. Sends the conversation history to an LLM API
3. If the LLM responds with a tool call (JSON with `tool`, `action`, `args`), dispatches it to the matching tool module
4. Appends the result to history and loops back to the LLM
5. Emits structured events at every step — all enriched with context for tracing

Every message (system prompt, user input, assistant response, tool result) is emitted as an `agent.message` event, making the event stream the single source of truth for conversation history. The DurableLog persists all events to DETS so history survives restarts.

Error and event types come from [Comn](https://github.com/imsmith/comn), the shared infrastructure library.

## Supervision Tree

```
LLMAgent.Supervisor (one_for_one)
├── Task.Supervisor (LLMAgent.TaskSup)
├── LLMAgent.Tools.Inotify.Watcher
├── DynamicSupervisor (LLMAgent.AgentSupervisor)
│   ├── LLMAgent (name: LLMAgent)       ← default agent, started by Application
│   └── LLMAgent (name: :agent_2)       ← started at runtime
├── Registry (LLMAgent.EventBus)
├── LLMAgent.EventLog
└── LLMAgent.DurableLog
```

Multiple agents run concurrently under `AgentSupervisor`. Each agent has its own history, role, and model configuration. Start and stop agents at runtime via `LLMAgent.AgentSupervisor.start_agent/1` and `stop_agent/1`.

## Tools

| Tool | Module | Actions | Description |
|------|--------|---------|-------------|
| bash | `Tools.Bash` | `exec` | Execute shell commands |
| file | `Tools.File` | `read`, `write`, `delete` | File system operations |
| web | `Tools.Web` | `get`, `post` | HTTP requests |
| net | `Tools.Net` | `list_interfaces`, `ping`, `resolve` | Network inspection |
| proc | `Tools.Proc` | `list`, `info` | Process inspection via /proc |
| systemd | `Tools.Systemd` | `status`, `start`, `stop`, `restart`, `list` | Service management |
| dbus | `Tools.DBus` | `list`, `introspect`, `call` | D-Bus messaging |
| udev | `Tools.Udev` | `list`, `info`, `usb`, `pci` | Device management |
| crypto | `Tools.Crypto` | `sha256`, `hmac`, `generate_key`, `generate_keypair`, `sign`, `verify` | Cryptographic operations |
| inotify | `Tools.Inotify` | `watch`, `poll`, `stop`, `list` | Filesystem event monitoring |

All tools implement the `LLMAgent.Tool` behaviour and return a standard format:

```elixir
{:ok, %{output: term(), metadata: map()}}
{:error, %Comn.Errors.ErrorStruct{}}
```

### Inotify

The inotify tool is backed by a supervised GenServer (`LLMAgent.Tools.Inotify.Watcher`) that manages `inotifywait -m` ports. Each watch gets an integer ID. Events buffer until polled.

```elixir
# Start watching a directory
{:ok, %{output: watch_id}} =
  LLMAgent.Tools.Inotify.perform("watch", %{"path" => "/tmp"})

# Poll for buffered events
{:ok, %{output: events}} =
  LLMAgent.Tools.Inotify.perform("poll", %{"watch_id" => watch_id})
# => [%{event: "CREATE", path: "/tmp/newfile", timestamp: ~U[...]}]

# Stop watching
{:ok, %{output: final_events}} =
  LLMAgent.Tools.Inotify.perform("stop", %{"watch_id" => watch_id})
```

### Adding a Tool

Implement the `LLMAgent.Tool` behaviour:

```elixir
defmodule LLMAgent.Tools.MyTool do
  @behaviour LLMAgent.Tool

  @impl true
  def describe, do: "Does something useful."

  @impl true
  def perform("action", %{"key" => value}) do
    {:ok, %{output: result, metadata: %{key: value}}}
  end

  def perform(_, _) do
    {:error, Comn.Errors.ErrorStruct.new("unknown_command", nil, "Unknown action")}
  end
end
```

Then register it in `LLMAgent.Tools`.

## Usage

```elixir
# Start the agent with defaults (gpt-4, localhost:4000)
{:ok, pid} = LLMAgent.start_link()

# Start with a specific role and model
{:ok, pid} = LLMAgent.start_link(
  name: :sysadmin_agent,
  role: :sysadmin,
  model: "llama3",
  api_host: "http://localhost:11434"
)

# Send a prompt — the agent calls the LLM asynchronously
LLMAgent.prompt({:global, :sysadmin_agent}, "What services are running?")
```

The LLM API must be OpenAI-compatible (`/chat/completions` endpoint). The agent expects tool calls as JSON in the response content:

```json
{"tool": "bash", "action": "exec", "args": {"command": "systemctl list-units --type=service"}}
```

### Multiple Agents

```elixir
# Start additional agents at runtime
LLMAgent.AgentSupervisor.start_agent(name: :researcher, role: :default, model: "gpt-4")
LLMAgent.AgentSupervisor.start_agent(name: :ops, role: :sysadmin, model: "llama3")

# Each agent maintains independent history and state
LLMAgent.prompt({:global, :researcher}, "Summarize this log file")
LLMAgent.prompt({:global, :ops}, "Check disk usage")

# List running agents
LLMAgent.AgentSupervisor.list_agents()

# Stop an agent
LLMAgent.AgentSupervisor.stop_agent(:researcher)
```

### Pluggable LLM Client

The agent uses `LLMAgent.LLMClient.OpenAI` by default. Implement the `LLMAgent.LLMClient` behaviour (`chat/2`) to use a different backend:

```elixir
LLMAgent.start_link(name: :custom, llm_client: MyApp.OllamaClient)
```

### Pluggable Memory

Agent memory defaults to `LLMAgent.Memory.ETS` (via `Comn.Repo.Table.ETS`). Implement the `LLMAgent.Memory` behaviour to swap backends:

```elixir
LLMAgent.start_link(name: :custom, memory: MyApp.RedisMemory)
```

## Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `:name` | `LLMAgent` | Process registration name (registered via `:global`) |
| `:role` | `:default` | Agent role — loads a role-specific system prompt |
| `:model` | `"gpt-4"` | Model name passed to the LLM API |
| `:api_host` | `"http://localhost:4000"` | Base URL of any OpenAI-compatible API |
| `:llm_client` | `LLMAgent.LLMClient.OpenAI` | Module implementing `LLMAgent.LLMClient` behaviour |
| `:memory` | `LLMAgent.Memory.ETS` | Module implementing `LLMAgent.Memory` behaviour |

Available roles: `:default`, `:sysadmin`

## Events

Every agent action emits a `Comn.Events.EventStruct` to EventLog (in-memory), DurableLog (DETS-backed), and EventBus (Registry-based pub/sub). Events are automatically enriched with `request_id`, `trace_id`, and `correlation_id` from the process-scoped `Comn.Contexts`.

| Topic | Type | When |
|-------|------|------|
| `agent.prompt` | `:prompt` | User sends a prompt |
| `agent.llm_response` | `:llm_response` | LLM responds |
| `agent.tool_dispatch` | `:tool_dispatch` | Agent dispatches a tool call |
| `agent.message` | `:message` | Any message appended to history (system, user, assistant, function) |
| `agent.error` | `:error` | Any failure |
| `tool.{name}` | `:invocation` | Tool executes (includes duration_ms) |
| `tool.inotify` | `:watch_started` | Inotify watch opened |
| `tool.inotify` | `:watch_stopped` | Inotify watch closed |
| `tool.inotify.event` | `:fs_event` | Filesystem event detected |

### Event-Sourced History

The `agent.message` events form a complete record of every conversation. On startup, the agent reconstructs its history from the DurableLog (surviving node restarts), falling back to Memory.ETS (surviving process restarts), then to a fresh system prompt.

```elixir
# Get conversation history for an agent from the durable log
LLMAgent.DurableLog.messages_for(:sysadmin_agent)
# => [%{role: "system", content: "..."}, %{role: "user", content: "..."}, ...]

# Get all events for an agent
LLMAgent.DurableLog.events_for(:sysadmin_agent)

# Get events since a timestamp
LLMAgent.DurableLog.events_for(:sysadmin_agent, since: "2026-02-23T00:00:00Z")
```

### Subscribing to Events

```elixir
# Subscribe to bash tool events
LLMAgent.EventBus.subscribe("tool.bash")
receive do
  {:event, "tool.bash", event} ->
    IO.inspect(event.data)
    # %{action: "exec", args: %{...}, result: :ok, duration_ms: 12,
    #   context: %{request_id: "req_...", trace_id: "trace_..."}}
end
```

### Querying the In-Memory Log

```elixir
LLMAgent.EventLog.for_topic("agent.error")
LLMAgent.EventLog.for_type(:invocation)
LLMAgent.EventLog.since("2026-02-23T00:00:00Z")
LLMAgent.EventLog.all()
```

### Emitting Events from Tools

Tools can emit domain-specific events using the public `LLMAgent.Events` module:

```elixir
LLMAgent.Events.emit(:my_event, "tool.mytool", %{key: "value"}, __MODULE__)
```

Context fields are attached automatically when a `Comn.Contexts` context is set on the current process.

## Key Modules

| Module | Purpose |
|--------|---------|
| `LLMAgent` | Main GenServer — prompt handling, tool dispatch, history |
| `LLMAgent.LLMClient` | Behaviour for LLM API clients (`chat/2`) |
| `LLMAgent.LLMClient.OpenAI` | OpenAI-compatible chat completions client |
| `LLMAgent.Memory` | Behaviour for agent memory backends |
| `LLMAgent.Memory.ETS` | ETS-backed memory via `Comn.Repo.Table.ETS` |
| `LLMAgent.AgentSupervisor` | DynamicSupervisor — `start_agent/stop_agent/list_agents` |
| `LLMAgent.DurableLog` | DETS-backed persistent event log |
| `LLMAgent.Events` | Event emission with context enrichment |
| `LLMAgent.EventBus` | Registry-based pub/sub |
| `LLMAgent.EventLog` | In-memory event log with query API |
| `LLMAgent.Tools` | Tool registry — maps atom names to modules |
| `LLMAgent.Tools.Inotify.Watcher` | GenServer managing inotifywait ports |
| `LLMAgent.Tool` | Behaviour: `describe/0`, `perform/2` |

## Utilities

| Utility | Actions | Description |
|---------|---------|-------------|
| `Utils.Encoder` | `base16`, `base64`, `base64url`, `base58`, `raw` | Encode binary data |
| `Utils.Decoder` | `base16`, `base64`, `base64url`, `base58`, `raw` | Decode encoded strings |
| `Utils.Time` | `now_iso8601` | UTC timestamp generation |
| `Utils.RequireBinary` | `check`, `check_many` | Verify system binaries exist |

```elixir
# Dispatch through the registry
LLMAgent.Utils.call(:encoder, "base16", %{"data" => "hello"})
# => {:ok, "68656c6c6f"}

# Or call directly
LLMAgent.Utils.Encoder.call("base64", %{"data" => "hello"})
# => {:ok, "aGVsbG8="}
```

## Dependencies

```elixir
defp deps do
  [
    {:req, "~> 0.5.0"},          # HTTP client
    {:jason, "~> 1.4"},          # JSON
    {:b58, "~> 1.0"},            # Base58 encoding
    {:comn, github: "imsmith/comn", tag: "v0.4.0"},
    {:mix_test_watch, "~> 1.1", only: [:dev], runtime: false}
  ]
end
```

Requires Elixir ~> 1.16.

System binaries used by tools: `bash`, `ip`, `ping`, `dig`, `ps`, `systemctl`, `busctl`, `lsblk`, `lsusb`, `lspci`, `udevadm`, `inotifywait`. Missing binaries log warnings at startup but don't prevent the agent from starting.

## Tests

```sh
mix test    # 96 doctests, 159 tests
```

Coverage includes agent lifecycle (multi-turn tool loops, stop/restart, concurrent agents, context propagation, event ordering, memory persistence, DurableLog reconstruction), all 10 tools, event wiring, context enrichment, durable event persistence, and error handling.

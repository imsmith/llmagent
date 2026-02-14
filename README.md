# LLMAgent

A GenServer-based AI agent framework for Elixir. LLMAgent connects to any OpenAI-compatible API, dispatches tool calls to local system tools, and records structured events for every action.

Built for Linux system administration — the default toolset gives an LLM hands-on access to bash, files, processes, networking, systemd, D-Bus, udev, and cryptographic operations.

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
└──────────┘
```

The agent runs as a GenServer. When it receives a prompt, it sends the conversation history to an LLM. If the LLM responds with a tool call (JSON with `tool`, `action`, `args`), the agent dispatches it, appends the result to history, and sends the result back to the LLM for a follow-up. Every step emits structured events through EventBus and EventLog.

Error and event types come from [Comn](../comn), the shared infrastructure library.

## Tools

| Tool | Actions | Description |
|------|---------|-------------|
| bash | `exec` | Execute shell commands |
| file | `read`, `write`, `delete` | File system operations |
| web | `get`, `post` | HTTP requests |
| net | `list_interfaces`, `ping`, `resolve` | Network operations |
| proc | `list`, `info` | Process inspection |
| systemd | `status`, `start`, `stop`, `restart`, `list` | Service management |
| dbus | `list`, `introspect`, `call` | D-Bus interaction |
| udev | `list`, `info`, `usb`, `pci` | Device management |
| crypto | `sha256`, `hmac`, `generate_key`, `generate_keypair`, `sign`, `verify` | Cryptographic operations |
| inotify | `watch`, `stop` | File system event monitoring |

All tools return a standard format:

```elixir
{:ok, %{output: term(), metadata: map()}}
{:error, %Comn.Errors.ErrorStruct{}}
```

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

# Send a prompt
LLMAgent.prompt({:global, :sysadmin_agent}, "What services are running?")
```

## Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `:name` | `LLMAgent` | Process registration name (registered via `:global`) |
| `:role` | `:default` | Agent role — loads a role-specific system prompt |
| `:model` | `"gpt-4"` | Model name passed to the LLM API |
| `:api_host` | `"http://localhost:4000"` | Base URL of any OpenAI-compatible API |

Available roles: `:default`, `:sysadmin`

## Events

Every agent action emits a `Comn.Events.EventStruct` to both EventLog (in-memory log) and EventBus (pub/sub):

| Topic | Type | When |
|-------|------|------|
| `agent.prompt` | `:prompt` | User sends a prompt |
| `agent.llm_response` | `:llm_response` | LLM responds |
| `agent.tool_dispatch` | `:tool_dispatch` | Agent dispatches a tool call |
| `agent.error` | `:error` | Any failure |
| `tool.{name}` | `:invocation` | Tool executes (includes duration_ms) |

```elixir
# Subscribe to tool events
LLMAgent.EventBus.subscribe("tool.bash")
receive do
  {:event, "tool.bash", event} -> IO.inspect(event.data)
end

# Query the log
LLMAgent.EventLog.for_topic("agent.error")
LLMAgent.EventLog.for_type(:invocation)
```

## Dependencies

LLMAgent depends on [Comn](../comn) for error and event types. Add both as path dependencies:

```elixir
defp deps do
  [
    {:errors, path: "../comn/apps/errors"},
    {:events, path: "../comn/apps/events"},
    {:req, "~> 0.5.0"},
    {:jason, "~> 1.4"}
  ]
end
```

## Tests

```sh
mix test                      # all tests
mix test --exclude integration # skip tests that hit real services
```

86 tests covering agent lifecycle, all 10 tools, event wiring, and error handling.

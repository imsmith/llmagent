# Taking LLMAgent for a Spin

## Prerequisites

- Elixir ~> 1.16, Erlang/OTP
- An OpenAI-compatible API endpoint (Ollama is easiest)
- `inotifywait` for inotify tool (optional — `apt install inotify-tools`)

## 1. Get Ollama Running

Ollama exposes an OpenAI-compatible endpoint at `http://localhost:11434/v1`.

```sh
# Install: https://ollama.com
ollama pull llama3.2
ollama serve   # if not already running as a service
```

Verify it's up:

```sh
curl -s http://localhost:11434/v1/chat/completions \
  -d '{"model":"llama3.2","messages":[{"role":"user","content":"say hi"}]}' \
  -H 'Content-Type: application/json' | jq .choices[0].message.content
```

## 2. Start the Agent

```sh
cd ~/github/llmagent
iex -S mix
```

The application starts a default agent automatically. It defaults to `gpt-4` on `localhost:4000`, which isn't what you want. Start a new one pointed at Ollama:

```elixir
# Stop the default agent (it'll fail to connect to localhost:4000, harmless but noisy)
LLMAgent.AgentSupervisor.stop_agent(LLMAgent)

# Start one pointed at Ollama
LLMAgent.AgentSupervisor.start_agent(
  name: :test,
  role: :sysadmin,
  model: "llama3.2",
  api_host: "http://localhost:11434/v1"
)
```

Or set env vars before starting:

```sh
LLMAGENT_MODEL=llama3.2 LLMAGENT_API_HOST=http://localhost:11434/v1 LLMAGENT_ROLE=sysadmin iex -S mix
```

This configures the default agent at startup, no need to stop/restart.

## 3. Send a Prompt

```elixir
LLMAgent.prompt({:global, :test}, "What's the hostname of this machine?")
```

This returns `:ok` immediately — the LLM call is async. The agent will:

1. Send the conversation history (system prompt + your message) to Ollama
2. If Ollama responds with tool-call JSON like `{"tool":"bash","action":"exec","args":{"command":"hostname"}}`, the agent executes it
3. The tool result gets fed back to the LLM for another round
4. When the LLM responds with plain text (not JSON), the loop ends

## 4. Inspect State

```elixir
# Check the conversation history
:sys.get_state({:global, :test})
|> Map.get(:history)
|> Enum.each(fn msg -> IO.puts("#{msg.role}: #{String.slice(msg.content, 0, 120)}") end)

# Check events
LLMAgent.EventLog.all()
|> Enum.each(fn e -> IO.puts("#{e.topic} [#{e.type}]") end)

# Check durable log
LLMAgent.DurableLog.messages_for(:test)

# Check events for this agent only
LLMAgent.DurableLog.events_for(:test)
```

## 5. Try the Tool Loop

Prompts that should trigger tool use with the sysadmin role:

```elixir
# Should trigger bash tool
LLMAgent.prompt({:global, :test}, "List the files in /tmp")

# Should trigger net tool (if the LLM figures out the JSON format)
LLMAgent.prompt({:global, :test}, "Ping localhost once")

# Should trigger proc tool
LLMAgent.prompt({:global, :test}, "What processes are using the most memory?")

# Should trigger crypto tool
LLMAgent.prompt({:global, :test}, "Generate a SHA256 hash of the string 'hello world'")
```

Give it a second or two after each prompt, then check history:

```elixir
:sys.get_state({:global, :test}).history |> List.last()
```

## 6. Subscribe to Events in Real Time

Open a second terminal, or run this before sending prompts:

```elixir
# In iex, subscribe to all tool events
for topic <- ["tool.bash", "tool.crypto", "tool.net", "tool.file", "agent.prompt", "agent.llm_response", "agent.tool_dispatch", "agent.message"] do
  LLMAgent.EventBus.subscribe(topic)
end

# Now events arrive in your mailbox
flush()
```

## 7. Multi-Agent

```elixir
LLMAgent.AgentSupervisor.start_agent(
  name: :agent_two,
  role: :default,
  model: "llama3.2",
  api_host: "http://localhost:11434/v1"
)

LLMAgent.prompt({:global, :agent_two}, "What is the capital of France?")

# Histories are isolated
LLMAgent.DurableLog.messages_for(:test)
LLMAgent.DurableLog.messages_for(:agent_two)
```

## 8. Restart Persistence

Test that DurableLog survives a restart:

```elixir
# Send a prompt and let it complete
LLMAgent.prompt({:global, :test}, "What's 2 + 2?")
Process.sleep(3000)

# Check history length
length(LLMAgent.DurableLog.messages_for(:test))

# Kill and restart the agent
LLMAgent.AgentSupervisor.stop_agent(:test)
LLMAgent.AgentSupervisor.start_agent(
  name: :test,
  role: :sysadmin,
  model: "llama3.2",
  api_host: "http://localhost:11434/v1"
)

# History should be restored from DurableLog
:sys.get_state({:global, :test}).history |> length()
```

## What to Watch For

**LLM doesn't produce valid tool JSON**: The sysadmin prompt tells the LLM the exact JSON format. Smaller models may not comply consistently. If the LLM responds with markdown-wrapped JSON or explanatory text around the JSON, the agent treats it as a plain text response (no tool dispatch). Try a larger model (`llama3.1:70b`, `qwen2.5:32b`) if tool calls aren't firing.

**No auth header**: The OpenAI client doesn't send an `Authorization` header. This is fine for Ollama. For OpenAI, Anthropic, or other authenticated APIs, you'd need to implement a custom `LLMClient` that adds the bearer token.

**Async responses**: `prompt/2` returns `:ok` immediately. The LLM response arrives asynchronously via a Task. There's no callback or return value — check history or subscribe to events to see results.

**DETS file location**: Events persist to `data/llmagent_events.dets` in the project root. Delete this file to start fresh.

## Cleanup

```elixir
# Clear durable log
LLMAgent.DurableLog.clear()

# Clear in-memory event log
LLMAgent.EventLog.clear()

# Stop agents
LLMAgent.AgentSupervisor.stop_agent(:test)
LLMAgent.AgentSupervisor.stop_agent(:agent_two)
```

```sh
# Remove DETS file
rm data/llmagent_events.dets
```

## Discovering LLM endpoints over mDNS

If you have one or more `llama.cpp` servers on the LAN announcing themselves over mDNS as `_llama._tcp` (e.g. via `avahi-publish-service` or built-in `--mdns`), the agent can pick them up automatically.

Prerequisites on the host running LLMAgent:

```bash
sudo apt install -y avahi-utils tcl
```

Add a discovery adapter to `config/runtime.exs`:

```elixir
config :LLMAgent, :discovery_adapters, [
  %{name: :avahi_llama,
    command: System.find_executable("tclsh"),
    args: [Path.expand("priv/discovery/avahi-llama.tcl", File.cwd!())],
    env: []}
]
```

Restart iex (full exit, not `r/0` — `runtime.exs` is read once at boot). The application starts the Tcl shim under `LLMAgent.Discovery.AdapterSupervisor`; the shim wraps `avahi-browse -p -r _llama._tcp` and ships register/expire EDN events into `LLMAgent.Tools.Discovery`.

Verify discovery:

```elixir
# Confirm the adapter is alive
DynamicSupervisor.which_children(LLMAgent.Discovery.AdapterSupervisor)
# [{:undefined, #PID<...>, :worker, [LLMAgent.Discovery.PortAdapter]}]

# Wait ~2s for the shim to enumerate the cache and emit
:timer.sleep(2000)

# Find the ads
LLMAgent.Tools.Discovery.find_all(LLMAgent.ToolQuery.new(%{coordinate: "compute.llm.chat"}))
# {:ok, [%ToolAd{id: "mdns:_llama._tcp:skynet001.local:8080", ...}, ...]}
```

Dispatch a real call. The dispatcher denies by default — pass an explicit policy:

```elixir
{:ok, [ad | _]} = LLMAgent.Tools.Discovery.find_all(
  LLMAgent.ToolQuery.new(%{coordinate: "compute.llm.chat"}))

policy = %LLMAgent.Tool.Policy{allow: ["compute.llm.*"]}

LLMAgent.Tool.Dispatcher.generate(ad, "chat",
  %{messages: [%{"role" => "user", "content" => "say hi in one sentence"}]},
  policy: policy)
# {:ok, "Hi there!", %{model: "gemma-4-26B-A4B-it-Q4_K_M.gguf", latency_ms: 6474}}
```

Each TXT record's `n_ctx` lands in `affordance.declared`, `slots` becomes `operational.actions["chat"].concurrency`, and `model` is carried in the binding payload — so capability-based selection (e.g. "give me an endpoint with ≥32k context") falls out of `ToolQuery` filters.

## Agent orchestration

The `agent` tool spawns child agents under the existing `AgentSupervisor`, and
the `tuple_space` tool gives them a coordination surface. Tuples from the LLM
are JSON arrays; `"_"` is the wildcard. Children's tool access is whitelisted
per spawn.

Async spawn:

```elixir
LLMAgent.Tools.Agent.perform("spawn", %{
  "name" => "worker",
  "prompt" => "summarize the contents of /etc/hostname",
  "tools" => ["file"],
  "mode" => "async"
})
```

Result lands in the default tuple space:

```elixir
LLMAgent.TupleSpace.in_(:default, {:agent_result, :worker, :_}, 30_000)
```

Sync spawn (blocks until the child finishes, then stops it):

```elixir
LLMAgent.Tools.Agent.perform("spawn", %{
  "name" => "summarizer",
  "prompt" => "say hello",
  "tools" => ["bash"],
  "mode" => "sync",
  "timeout" => 30_000
})
```

Through the tuple_space tool directly:

```elixir
LLMAgent.Tools.TupleSpace.perform("write",
  %{"space" => "default", "tuple" => ["task", "worker", "do thing"]})

LLMAgent.Tools.TupleSpace.perform("take",
  %{"space" => "default", "pattern" => ["task", "_", "_"], "timeout" => 5_000})
```

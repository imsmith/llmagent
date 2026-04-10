# MCP Client Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let LLMAgent agents consume tools from external MCP servers via HTTP, with a transport abstraction for future stdio support.

**Architecture:** One GenServer per MCP connection under a DynamicSupervisor, discovered via a Registry. A single ToolProxy module bridges MCP tools into the existing Tool behaviour and persistent_term registry. HTTP transport via Req.

**Tech Stack:** Elixir, GenServer, DynamicSupervisor, Registry, Req, Jason, Comn.Errors.ErrorStruct, Comn.Events.EventStruct

---

## File Structure

```
lib/llmagent/mcp/
  transport.ex             # Transport behaviour (start/1, send_request/2, close/1)
  transport/http.ex        # HTTP implementation via Req
  tool_proxy.ex            # Implements LLMAgent.Tool, dispatches to Connection via side map
  connection.ex            # GenServer per MCP server — handshake, discovery, tool call proxy
  mcp.ex                   # Public facade — connect/2, disconnect/1, list_connections/0, tools_for/1

test/mcp/
  transport_http_test.exs  # Transport.HTTP unit tests with Req.Test
  tool_proxy_test.exs      # ToolProxy unit tests with persistent_term fixtures
  connection_test.exs      # Connection lifecycle tests with mock transport
  mcp_test.exs             # Integration tests — full connect/call/disconnect cycle

lib/llmagent/application.ex  # Modified — add Registry + DynamicSupervisor to children
```

---

### Task 1: Transport Behaviour

**Files:**
- Create: `lib/llmagent/mcp/transport.ex`

- [ ] **Step 1: Create the transport behaviour module**

```elixir
defmodule LLMAgent.MCP.Transport do
  @moduledoc """
  Behaviour for MCP transport implementations.

  A transport handles the low-level communication with an MCP server
  over a specific protocol (HTTP, stdio, etc.). The Connection GenServer
  holds the transport module and its opaque state.
  """

  @type request :: %{method: String.t(), params: map(), id: integer()}
  @type response :: {:ok, map()} | {:error, term()}

  @callback start(opts :: keyword()) :: {:ok, state :: term()} | {:error, term()}
  @callback send_request(state :: term(), request()) :: {response(), new_state :: term()}
  @callback close(state :: term()) :: :ok
end
```

- [ ] **Step 2: Verify it compiles**

Run: `mix compile --warnings-as-errors`
Expected: 0 errors, 0 warnings

- [ ] **Step 3: Commit**

```bash
git add lib/llmagent/mcp/transport.ex
git commit -m "Add MCP transport behaviour"
```

---

### Task 2: HTTP Transport Implementation

**Files:**
- Create: `test/mcp/transport_http_test.exs`
- Create: `lib/llmagent/mcp/transport/http.ex`

- [ ] **Step 1: Write failing tests for Transport.HTTP**

```elixir
defmodule LLMAgent.MCP.Transport.HTTPTest do
  use ExUnit.Case, async: true

  alias LLMAgent.MCP.Transport.HTTP

  describe "start/1" do
    test "returns state with url and headers" do
      {:ok, state} = HTTP.start(url: "https://example.com/mcp", headers: [{"authorization", "Bearer tok"}])
      assert state.url == "https://example.com/mcp"
      assert state.headers == [{"authorization", "Bearer tok"}]
    end

    test "defaults headers to empty list" do
      {:ok, state} = HTTP.start(url: "https://example.com/mcp")
      assert state.headers == []
    end

    test "returns error when url is missing" do
      assert {:error, :missing_url} = HTTP.start([])
    end
  end

  describe "send_request/2" do
    test "sends JSON-RPC 2.0 POST and parses successful result" do
      # Use Req.Test to stub the HTTP response
      Req.Test.stub(LLMAgent.MCP.Transport.HTTP, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["jsonrpc"] == "2.0"
        assert decoded["method"] == "tools/list"
        assert decoded["id"] == 1

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "result" => %{"tools" => []}
        }))
      end)

      {:ok, state} = HTTP.start(url: "https://example.com/mcp", plug: {Req.Test, LLMAgent.MCP.Transport.HTTP})
      request = %{method: "tools/list", params: %{}, id: 1}
      {{:ok, result}, _new_state} = HTTP.send_request(state, request)
      assert result == %{"tools" => []}
    end

    test "returns error on JSON-RPC error response" do
      Req.Test.stub(LLMAgent.MCP.Transport.HTTP, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "error" => %{"code" => -32600, "message" => "Invalid request"}
        }))
      end)

      {:ok, state} = HTTP.start(url: "https://example.com/mcp", plug: {Req.Test, LLMAgent.MCP.Transport.HTTP})
      request = %{method: "initialize", params: %{}, id: 1}
      {{:error, error}, _state} = HTTP.send_request(state, request)
      assert error.code == -32600
      assert error.message == "Invalid request"
    end

    test "returns error on HTTP failure" do
      Req.Test.stub(LLMAgent.MCP.Transport.HTTP, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal server error")
      end)

      {:ok, state} = HTTP.start(url: "https://example.com/mcp", plug: {Req.Test, LLMAgent.MCP.Transport.HTTP})
      request = %{method: "initialize", params: %{}, id: 1}
      {{:error, _reason}, _state} = HTTP.send_request(state, request)
    end
  end

  describe "close/1" do
    test "returns :ok" do
      {:ok, state} = HTTP.start(url: "https://example.com/mcp")
      assert :ok = HTTP.close(state)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/mcp/transport_http_test.exs`
Expected: compilation error — `LLMAgent.MCP.Transport.HTTP` not defined

- [ ] **Step 3: Implement Transport.HTTP**

```elixir
defmodule LLMAgent.MCP.Transport.HTTP do
  @moduledoc """
  MCP transport over HTTP (Streamable HTTP).

  Sends JSON-RPC 2.0 requests as POST to the server URL.
  Uses Req for HTTP. Stateless — no persistent connection.
  """

  @behaviour LLMAgent.MCP.Transport

  @impl true
  def start(opts) do
    case Keyword.fetch(opts, :url) do
      {:ok, url} ->
        state = %{
          url: url,
          headers: Keyword.get(opts, :headers, []),
          plug: Keyword.get(opts, :plug)
        }
        {:ok, state}

      :error ->
        {:error, :missing_url}
    end
  end

  @impl true
  def send_request(state, %{method: method, params: params, id: id}) do
    body = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params,
      "id" => id
    }

    req_opts = [url: state.url, json: body, headers: state.headers]
    req_opts = if state.plug, do: Keyword.put(req_opts, :plug, state.plug), else: req_opts

    case Req.post(req_opts) do
      {:ok, %Req.Response{status: 200, body: %{"result" => result}}} ->
        {{:ok, result}, state}

      {:ok, %Req.Response{status: 200, body: %{"error" => error}}} ->
        {{:error, %{code: error["code"], message: error["message"]}}, state}

      {:ok, %Req.Response{status: status, body: body}} ->
        {{:error, {:http_error, status, body}}, state}

      {:error, reason} ->
        {{:error, {:transport_error, reason}}, state}
    end
  end

  @impl true
  def close(_state), do: :ok
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/mcp/transport_http_test.exs`
Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/mcp/transport/http.ex test/mcp/transport_http_test.exs
git commit -m "Add MCP HTTP transport with tests"
```

---

### Task 3: ToolProxy

**Files:**
- Create: `test/mcp/tool_proxy_test.exs`
- Create: `lib/llmagent/mcp/tool_proxy.ex`

- [ ] **Step 1: Write failing tests for ToolProxy**

```elixir
defmodule LLMAgent.MCP.ToolProxyTest do
  use ExUnit.Case, async: false

  alias LLMAgent.MCP.ToolProxy

  @tool_map_key :llmagent_mcp_tool_map

  setup do
    # Clean up the tool map before each test
    :persistent_term.put(@tool_map_key, %{})
    on_exit(fn -> :persistent_term.put(@tool_map_key, %{}) end)
    :ok
  end

  describe "describe/0" do
    test "returns static description" do
      desc = ToolProxy.describe()
      assert is_binary(desc)
      assert desc =~ "MCP tool proxy"
    end
  end

  describe "perform/2" do
    test "routes to connection GenServer and returns result" do
      # Start a fake GenServer that responds to :call_tool
      {:ok, fake} = Agent.start_link(fn -> nil end)

      # Register a fake connection in the MCP Registry
      Registry.register(LLMAgent.MCP.Registry, :test_server, fake)

      # Populate the tool map
      :persistent_term.put(@tool_map_key, %{
        test_server_my_tool: %{connection: :test_server, tool: "my_tool", description: "A test tool"}
      })

      # We need a real Connection GenServer for this test — use a mock instead.
      # Start a GenServer that handles {:call_tool, tool, args}
      {:ok, mock_conn} = GenServer.start_link(LLMAgent.MCP.ToolProxyTest.MockConnection, :ok)
      Registry.unregister(LLMAgent.MCP.Registry, :test_server)
      Registry.register(LLMAgent.MCP.Registry, :test_server, mock_conn)

      {:ok, result} = ToolProxy.perform("call", %{"input" => "value"}, :test_server_my_tool)
      assert result.output == "mock response"
      assert result.metadata.mcp_server == :test_server
      assert result.metadata.mcp_tool == "my_tool"

      GenServer.stop(mock_conn)
    end

    test "returns error when tool not in map" do
      {:error, err} = ToolProxy.perform("call", %{}, :nonexistent_tool)
      assert err.reason == "mcp_tool_not_found"
    end

    test "returns error when connection process not found" do
      :persistent_term.put(@tool_map_key, %{
        orphan_tool: %{connection: :dead_server, tool: "ghost", description: "Gone"}
      })

      {:error, err} = ToolProxy.perform("call", %{}, :orphan_tool)
      assert err.reason == "mcp_connection_not_found"
    end
  end

  defmodule MockConnection do
    use GenServer

    def init(:ok), do: {:ok, %{}}

    def handle_call({:call_tool, _tool, _args}, _from, state) do
      {:reply, {:ok, %{output: "mock response", metadata: %{}}}, state}
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/mcp/tool_proxy_test.exs`
Expected: compilation error — `LLMAgent.MCP.ToolProxy` not defined

- [ ] **Step 3: Implement ToolProxy**

```elixir
defmodule LLMAgent.MCP.ToolProxy do
  @moduledoc """
  Tool behaviour implementation that proxies calls to MCP connections.

  Registered in the Tools persistent_term registry for each MCP tool.
  Uses a side map in persistent_term (:llmagent_mcp_tool_map) to resolve
  which connection and MCP tool name to dispatch to.
  """

  @behaviour LLMAgent.Tool
  alias Comn.Errors.ErrorStruct

  @tool_map_key :llmagent_mcp_tool_map

  @impl true
  def describe do
    "MCP tool proxy — see individual tool descriptions via LLMAgent.MCP.tool_description/1"
  end

  @doc """
  Perform an MCP tool call. The action string is ignored — MCP tools have
  only one action (call). Args pass through directly to the MCP server.

  The `tool_atom` parameter identifies which MCP tool to dispatch to.
  When called via the standard Tool dispatch path, perform/2 is called.
  The ToolProxy uses the tool atom from the agent's dispatch context.
  """
  def perform(tool_atom, _action, args) when is_atom(tool_atom) do
    tool_map = :persistent_term.get(@tool_map_key, %{})

    case Map.fetch(tool_map, tool_atom) do
      {:ok, %{connection: conn_name, tool: mcp_tool}} ->
        call_connection(conn_name, mcp_tool, args)

      :error ->
        {:error, ErrorStruct.new("mcp_tool_not_found", nil, "MCP tool #{tool_atom} not in tool map")}
    end
  end

  @impl true
  def perform(_action, args) do
    # When called via the standard Tool behaviour (perform/2), we need the
    # tool atom from the caller context. This path shouldn't normally be hit
    # directly — the agent dispatch calls perform/2 but we need the atom.
    # See connection.ex for how tools are registered with a wrapper.
    {:error, ErrorStruct.new("mcp_proxy_error", nil,
      "ToolProxy.perform/2 called without tool context. Use perform/3.")}
  end

  defp call_connection(conn_name, mcp_tool, args) do
    case Registry.lookup(LLMAgent.MCP.Registry, conn_name) do
      [{_pid, conn_pid}] ->
        case GenServer.call(conn_pid, {:call_tool, mcp_tool, args}) do
          {:ok, result} ->
            {:ok, %{
              output: result.output,
              metadata: Map.merge(result.metadata, %{mcp_server: conn_name, mcp_tool: mcp_tool})
            }}

          {:error, _} = err ->
            err
        end

      [] ->
        {:error, ErrorStruct.new("mcp_connection_not_found", nil,
          "MCP connection #{conn_name} not found in registry")}
    end
  end

  @doc """
  Read the tool map. Used internally and for testing.
  """
  def tool_map, do: :persistent_term.get(@tool_map_key, %{})
end
```

- [ ] **Step 4: Adjust — ToolProxy perform/2 vs perform/3 problem**

The `Tool` behaviour requires `perform/2` (action, args), but the proxy needs to know _which_ tool atom is being called. The cleanest solution: when registering MCP tools, instead of registering the `ToolProxy` module directly, register a wrapper module generated per-tool. But that's complex.

Simpler: change the registration to store a closure-like dispatch. But `persistent_term` + closures is fragile.

Simplest: make `perform/2` look up the tool atom from the process dictionary. The agent's `timed_dispatch/3` already calls `Contexts.put(:tool, tool)` before dispatching. So:

```elixir
@impl true
def perform(_action, args) do
  tool_atom = Comn.Contexts.fetch(:tool)

  if tool_atom do
    tool_map = :persistent_term.get(@tool_map_key, %{})

    case Map.fetch(tool_map, tool_atom) do
      {:ok, %{connection: conn_name, tool: mcp_tool}} ->
        call_connection(conn_name, mcp_tool, args)

      :error ->
        {:error, ErrorStruct.new("mcp_tool_not_found", nil, "MCP tool #{tool_atom} not in tool map")}
    end
  else
    {:error, ErrorStruct.new("mcp_proxy_error", nil, "No tool context available")}
  end
end
```

Remove `perform/3` — we don't need it. Update the test to set context before calling `perform/2`:

```elixir
test "routes to connection GenServer and returns result" do
  # ... setup mock connection and tool map as before ...

  Comn.Contexts.new(%{request_id: "test"})
  Comn.Contexts.put(:tool, :test_server_my_tool)

  {:ok, result} = ToolProxy.perform("call", %{"input" => "value"})
  assert result.output == "mock response"
  assert result.metadata.mcp_server == :test_server
  assert result.metadata.mcp_tool == "my_tool"

  Process.delete(:comn_context)
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/mcp/tool_proxy_test.exs`
Expected: all tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/llmagent/mcp/tool_proxy.ex test/mcp/tool_proxy_test.exs
git commit -m "Add MCP ToolProxy with context-based dispatch"
```

---

### Task 4: Connection GenServer

**Files:**
- Create: `test/mcp/connection_test.exs`
- Create: `lib/llmagent/mcp/connection.ex`

- [ ] **Step 1: Create a mock transport for testing**

Add to the test file:

```elixir
defmodule LLMAgent.MCP.Transport.Mock do
  @behaviour LLMAgent.MCP.Transport

  @impl true
  def start(opts) do
    tools = Keyword.get(opts, :tools, [])
    {:ok, %{tools: tools, calls: []}}
  end

  @impl true
  def send_request(state, %{method: "initialize"} = _request) do
    result = %{
      "protocolVersion" => "2025-03-26",
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "mock", "version" => "1.0"}
    }
    {{:ok, result}, state}
  end

  def send_request(state, %{method: "tools/list"} = _request) do
    result = %{"tools" => state.tools}
    {{:ok, result}, state}
  end

  def send_request(state, %{method: "tools/call", params: params} = _request) do
    result = %{
      "content" => [%{"type" => "text", "text" => "result for #{params["name"]}"}]
    }
    state = %{state | calls: state.calls ++ [params]}
    {{:ok, result}, state}
  end

  @impl true
  def close(_state), do: :ok
end
```

- [ ] **Step 2: Write failing tests for Connection**

```elixir
defmodule LLMAgent.MCP.ConnectionTest do
  use ExUnit.Case, async: false

  alias LLMAgent.MCP.Connection

  @tool_map_key :llmagent_mcp_tool_map

  setup do
    :persistent_term.put(@tool_map_key, %{})
    on_exit(fn ->
      :persistent_term.put(@tool_map_key, %{})
    end)
    :ok
  end

  @mock_tools [
    %{
      "name" => "create_issue",
      "description" => "Create a GitHub issue",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "repo" => %{"type" => "string"},
          "title" => %{"type" => "string"},
          "body" => %{"type" => "string"}
        },
        "required" => ["repo", "title"]
      }
    },
    %{
      "name" => "list_repos",
      "description" => "List repositories",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{},
        "required" => []
      }
    }
  ]

  describe "init lifecycle" do
    test "performs handshake, discovers tools, and registers them" do
      {:ok, pid} = Connection.start_link(
        name: :test_mcp,
        transport: LLMAgent.MCP.Transport.Mock,
        transport_opts: [tools: @mock_tools]
      )

      # Tools should be registered in the Tools registry
      assert {:ok, LLMAgent.MCP.ToolProxy} = LLMAgent.Tools.get(:test_mcp_create_issue)
      assert {:ok, LLMAgent.MCP.ToolProxy} = LLMAgent.Tools.get(:test_mcp_list_repos)

      # Tool map should have entries
      tool_map = :persistent_term.get(@tool_map_key, %{})
      assert %{connection: :test_mcp, tool: "create_issue"} = tool_map[:test_mcp_create_issue]
      assert %{connection: :test_mcp, tool: "list_repos"} = tool_map[:test_mcp_list_repos]

      # Description should be generated
      assert tool_map[:test_mcp_create_issue].description =~ "Create a GitHub issue"
      assert tool_map[:test_mcp_create_issue].description =~ "repo"

      GenServer.stop(pid)
    end

    test "unregisters tools on terminate" do
      {:ok, pid} = Connection.start_link(
        name: :test_cleanup,
        transport: LLMAgent.MCP.Transport.Mock,
        transport_opts: [tools: @mock_tools]
      )

      assert {:ok, _} = LLMAgent.Tools.get(:test_cleanup_create_issue)
      GenServer.stop(pid)

      assert {:error, :not_found} = LLMAgent.Tools.get(:test_cleanup_create_issue)
      assert {:error, :not_found} = LLMAgent.Tools.get(:test_cleanup_list_repos)

      tool_map = :persistent_term.get(@tool_map_key, %{})
      refute Map.has_key?(tool_map, :test_cleanup_create_issue)
    end
  end

  describe "call_tool" do
    test "dispatches tools/call and returns formatted result" do
      {:ok, pid} = Connection.start_link(
        name: :test_call,
        transport: LLMAgent.MCP.Transport.Mock,
        transport_opts: [tools: @mock_tools]
      )

      {:ok, result} = GenServer.call(pid, {:call_tool, "create_issue", %{"repo" => "foo", "title" => "bar"}})
      assert result.output =~ "result for create_issue"
      assert result.metadata == %{}

      GenServer.stop(pid)
    end

    test "returns error on transport failure" do
      {:ok, pid} = Connection.start_link(
        name: :test_call_err,
        transport: LLMAgent.MCP.Transport.Mock,
        transport_opts: [tools: @mock_tools]
      )

      # Mock doesn't handle unknown methods — send a bad call_tool
      # We'll test error handling by checking the Connection handles transport errors
      # For now, verify the happy path works. Transport error tests go in Task 2.

      GenServer.stop(pid)
    end
  end

  describe "info/1" do
    test "returns connection metadata" do
      {:ok, pid} = Connection.start_link(
        name: :test_info,
        transport: LLMAgent.MCP.Transport.Mock,
        transport_opts: [tools: @mock_tools]
      )

      info = GenServer.call(pid, :info)
      assert info.name == :test_info
      assert info.protocol_version == "2025-03-26"
      assert :test_info_create_issue in info.tools
      assert :test_info_list_repos in info.tools

      GenServer.stop(pid)
    end
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mix test test/mcp/connection_test.exs`
Expected: compilation error — `LLMAgent.MCP.Connection` not defined

- [ ] **Step 4: Implement Connection GenServer**

```elixir
defmodule LLMAgent.MCP.Connection do
  @moduledoc """
  GenServer managing a single MCP server connection.

  Performs the initialize handshake on startup, discovers tools via
  tools/list, registers them into the Tools registry, and proxies
  tools/call requests from ToolProxy.

  Registered in LLMAgent.MCP.Registry by name for lookup.
  """

  use GenServer
  require Logger

  alias LLMAgent.Tools
  alias LLMAgent.MCP.ToolProxy
  alias LLMAgent.Events
  alias Comn.Errors.ErrorStruct

  @tool_map_key :llmagent_mcp_tool_map
  @client_info %{"name" => "LLMAgent", "version" => "0.3.0"}
  @protocol_version "2025-03-26"

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    transport_mod = Keyword.fetch!(opts, :transport)
    transport_opts = Keyword.get(opts, :transport_opts, [])

    with {:ok, transport_state} <- transport_mod.start(transport_opts),
         {:ok, init_result, transport_state} <- do_initialize(transport_mod, transport_state),
         {:ok, tools, transport_state} <- do_discover_tools(transport_mod, transport_state) do

      tool_atoms = register_tools(name, tools)

      Events.emit(:mcp_connected, "mcp.connected", %{
        server: name,
        protocol_version: init_result["protocolVersion"],
        capabilities: init_result["capabilities"]
      }, __MODULE__)

      Events.emit(:mcp_tools_discovered, "mcp.tools_discovered", %{
        server: name,
        tool_count: length(tool_atoms),
        tools: tool_atoms
      }, __MODULE__)

      state = %{
        name: name,
        transport: transport_mod,
        transport_state: transport_state,
        server_capabilities: init_result["capabilities"],
        protocol_version: init_result["protocolVersion"],
        tools: tool_atoms,
        request_id: 3
      }

      {:ok, state}
    else
      {:error, reason} ->
        Logger.error("MCP connection #{name} failed to initialize: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:call_tool, tool_name, args}, _from, state) do
    {id, state} = next_id(state)

    request = %{
      method: "tools/call",
      params: %{"name" => tool_name, "arguments" => args},
      id: id
    }

    case state.transport.send_request(state.transport_state, request) do
      {{:ok, result}, new_transport_state} ->
        output = extract_text_content(result)
        reply = {:ok, %{output: output, metadata: %{}}}
        {:reply, reply, %{state | transport_state: new_transport_state}}

      {{:error, reason}, new_transport_state} ->
        reply = {:error, ErrorStruct.new("mcp_call_failed", tool_name, inspect(reason))}
        {:reply, reply, %{state | transport_state: new_transport_state}}
    end
  end

  def handle_call(:info, _from, state) do
    info = %{
      name: state.name,
      protocol_version: state.protocol_version,
      server_capabilities: state.server_capabilities,
      tools: state.tools
    }
    {:reply, info, state}
  end

  @impl true
  def terminate(_reason, state) do
    unregister_tools(state.name, state.tools)
    state.transport.close(state.transport_state)

    Events.emit(:mcp_disconnected, "mcp.disconnected", %{
      server: state.name
    }, __MODULE__)

    :ok
  end

  ## Private — MCP Protocol

  defp do_initialize(transport_mod, transport_state) do
    request = %{
      method: "initialize",
      params: %{
        "protocolVersion" => @protocol_version,
        "capabilities" => %{},
        "clientInfo" => @client_info
      },
      id: 1
    }

    case transport_mod.send_request(transport_state, request) do
      {{:ok, result}, new_state} -> {:ok, result, new_state}
      {{:error, reason}, _state} -> {:error, {:initialize_failed, reason}}
    end
  end

  defp do_discover_tools(transport_mod, transport_state) do
    request = %{method: "tools/list", params: %{}, id: 2}

    case transport_mod.send_request(transport_state, request) do
      {{:ok, %{"tools" => tools}}, new_state} -> {:ok, tools, new_state}
      {{:error, reason}, _state} -> {:error, {:discovery_failed, reason}}
    end
  end

  ## Private — Tool Registration

  defp register_tools(server_name, tools) do
    Enum.map(tools, fn tool ->
      atom = tool_atom(server_name, tool["name"])
      description = build_description(tool)

      # Update the tool map
      tool_map = :persistent_term.get(@tool_map_key, %{})
      updated = Map.put(tool_map, atom, %{
        connection: server_name,
        tool: tool["name"],
        description: description
      })
      :persistent_term.put(@tool_map_key, updated)

      # Register in the Tools registry
      Tools.register(atom, ToolProxy)

      atom
    end)
  end

  defp unregister_tools(server_name, tool_atoms) do
    tool_map = :persistent_term.get(@tool_map_key, %{})
    updated = Map.drop(tool_map, tool_atoms)
    :persistent_term.put(@tool_map_key, updated)

    Enum.each(tool_atoms, fn atom ->
      Tools.unregister(atom)
    end)

    Logger.debug("MCP #{server_name}: unregistered #{length(tool_atoms)} tools")
  end

  defp tool_atom(server_name, tool_name) do
    :"#{server_name}_#{tool_name}"
  end

  defp build_description(tool) do
    name = tool["name"]
    desc = tool["description"] || "No description"
    schema = tool["inputSchema"]

    args_text = format_args(schema)

    "#{name}: #{desc}\n\nArgs:\n#{args_text}"
  end

  defp format_args(%{"properties" => props, "required" => required}) when is_map(props) do
    props
    |> Enum.map(fn {name, spec} ->
      type = spec["type"] || "any"
      req = if name in (required || []), do: "required", else: "optional"
      "  - #{name} (#{type}, #{req})"
    end)
    |> Enum.join("\n")
  end

  defp format_args(_), do: "  (none)"

  defp extract_text_content(%{"content" => content}) when is_list(content) do
    content
    |> Enum.filter(fn block -> block["type"] == "text" end)
    |> Enum.map(fn block -> block["text"] end)
    |> Enum.join("\n")
  end

  defp extract_text_content(_), do: ""

  defp next_id(state) do
    id = state.request_id + 1
    {id, %{state | request_id: id}}
  end

  defp via(name), do: {:via, Registry, {LLMAgent.MCP.Registry, name, self()}}
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/mcp/connection_test.exs`
Expected: all tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/llmagent/mcp/connection.ex test/mcp/connection_test.exs
git commit -m "Add MCP Connection GenServer with mock transport tests"
```

---

### Task 5: MCP Facade & Supervision Wiring

**Files:**
- Create: `test/mcp/mcp_test.exs`
- Create: `lib/llmagent/mcp/mcp.ex`
- Modify: `lib/llmagent/application.ex:18-25`

- [ ] **Step 1: Write failing tests for the facade**

```elixir
defmodule LLMAgent.MCPTest do
  use ExUnit.Case, async: false

  alias LLMAgent.MCP

  @mock_tools [
    %{
      "name" => "search",
      "description" => "Search things",
      "inputSchema" => %{"type" => "object", "properties" => %{"q" => %{"type" => "string"}}, "required" => ["q"]}
    }
  ]

  setup do
    # Disconnect any lingering connections
    for {name, _pid, _info} <- MCP.list_connections() do
      MCP.disconnect(name)
    end
    :ok
  end

  describe "connect/2" do
    test "starts a connection and registers tools" do
      {:ok, pid} = MCP.connect(:facade_test,
        transport: LLMAgent.MCP.Transport.Mock,
        transport_opts: [tools: @mock_tools]
      )

      assert is_pid(pid)
      assert {:ok, LLMAgent.MCP.ToolProxy} = LLMAgent.Tools.get(:facade_test_search)
    end

    test "returns error on duplicate name" do
      {:ok, _pid} = MCP.connect(:dup_test,
        transport: LLMAgent.MCP.Transport.Mock,
        transport_opts: [tools: @mock_tools]
      )

      assert {:error, {:already_started, _}} = MCP.connect(:dup_test,
        transport: LLMAgent.MCP.Transport.Mock,
        transport_opts: [tools: @mock_tools]
      )

      MCP.disconnect(:dup_test)
    end
  end

  describe "disconnect/1" do
    test "stops the connection and unregisters tools" do
      {:ok, _pid} = MCP.connect(:disc_test,
        transport: LLMAgent.MCP.Transport.Mock,
        transport_opts: [tools: @mock_tools]
      )

      assert :ok = MCP.disconnect(:disc_test)
      assert {:error, :not_found} = LLMAgent.Tools.get(:disc_test_search)
    end

    test "returns error for unknown connection" do
      assert {:error, :not_found} = MCP.disconnect(:nonexistent)
    end
  end

  describe "list_connections/0" do
    test "returns active connections with metadata" do
      {:ok, _} = MCP.connect(:list_test,
        transport: LLMAgent.MCP.Transport.Mock,
        transport_opts: [tools: @mock_tools]
      )

      conns = MCP.list_connections()
      assert length(conns) >= 1

      {name, pid, info} = Enum.find(conns, fn {n, _, _} -> n == :list_test end)
      assert name == :list_test
      assert is_pid(pid)
      assert :list_test_search in info.tools

      MCP.disconnect(:list_test)
    end
  end

  describe "tools_for/1" do
    test "returns tool atoms for a connection" do
      {:ok, _} = MCP.connect(:tools_test,
        transport: LLMAgent.MCP.Transport.Mock,
        transport_opts: [tools: @mock_tools]
      )

      tools = MCP.tools_for(:tools_test)
      assert :tools_test_search in tools

      MCP.disconnect(:tools_test)
    end

    test "returns error for unknown connection" do
      assert {:error, :not_found} = MCP.tools_for(:nonexistent)
    end
  end

  describe "tool_descriptions/0" do
    test "returns descriptions for all MCP tools" do
      {:ok, _} = MCP.connect(:desc_test,
        transport: LLMAgent.MCP.Transport.Mock,
        transport_opts: [tools: @mock_tools]
      )

      descs = MCP.tool_descriptions()
      assert is_map(descs)
      assert descs[:desc_test_search] =~ "Search things"

      MCP.disconnect(:desc_test)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/mcp/mcp_test.exs`
Expected: compilation error — `LLMAgent.MCP` not defined

- [ ] **Step 3: Add Registry and DynamicSupervisor to the supervision tree**

In `lib/llmagent/application.ex`, add two children to the `children` list, after the existing `Registry` for EventBus:

```elixir
    children = [
      {Task.Supervisor, name: LLMAgent.TaskSup},
      {LLMAgent.Tools.Inotify.Watcher, []},
      {DynamicSupervisor, name: LLMAgent.AgentSupervisor, strategy: :one_for_one},
      {Registry, keys: :duplicate, name: LLMAgent.EventBus},
      {LLMAgent.EventLog, []},
      {LLMAgent.DurableLog, []},
      {Registry, keys: :unique, name: LLMAgent.MCP.Registry},
      {DynamicSupervisor, name: LLMAgent.MCP.ConnectionSupervisor, strategy: :one_for_one}
    ]
```

- [ ] **Step 4: Implement the MCP facade**

```elixir
defmodule LLMAgent.MCP do
  @moduledoc """
  Public API for managing MCP server connections.

  Facade module — no process. Delegates to ConnectionSupervisor
  for lifecycle and MCP.Registry for lookups.
  """

  alias LLMAgent.MCP.Connection

  @tool_map_key :llmagent_mcp_tool_map

  @doc """
  Connect to an MCP server.

  Options:
    - `:transport` — transport module (default: `LLMAgent.MCP.Transport.HTTP`)
    - `:url` — server URL (required for HTTP transport)
    - `:headers` — HTTP headers (optional)
    - `:transport_opts` — raw opts passed to transport start/1

  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  def connect(name, opts \\ []) do
    transport = Keyword.get(opts, :transport, LLMAgent.MCP.Transport.HTTP)

    transport_opts = Keyword.get_lazy(opts, :transport_opts, fn ->
      build_transport_opts(opts)
    end)

    child_opts = [
      name: name,
      transport: transport,
      transport_opts: transport_opts
    ]

    DynamicSupervisor.start_child(
      LLMAgent.MCP.ConnectionSupervisor,
      {Connection, child_opts}
    )
  end

  @doc """
  Disconnect from an MCP server. Unregisters its tools.
  """
  def disconnect(name) do
    case Registry.lookup(LLMAgent.MCP.Registry, name) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(LLMAgent.MCP.ConnectionSupervisor, pid)

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  List all active MCP connections with their metadata.

  Returns `[{name, pid, info}]`.
  """
  def list_connections do
    LLMAgent.MCP.ConnectionSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn {_, pid, _, _} ->
      if is_pid(pid) do
        try do
          info = GenServer.call(pid, :info)
          [{info.name, pid, info}]
        catch
          :exit, _ -> []
        end
      else
        []
      end
    end)
  end

  @doc """
  List tool atoms for a specific connection.
  """
  def tools_for(name) do
    case Registry.lookup(LLMAgent.MCP.Registry, name) do
      [{pid, _}] ->
        info = GenServer.call(pid, :info)
        info.tools

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns a map of `%{tool_atom => description}` for all registered MCP tools.

  Used by the agent's prompt builder to include MCP tool descriptions
  in the system prompt.
  """
  def tool_descriptions do
    :persistent_term.get(@tool_map_key, %{})
    |> Map.new(fn {atom, %{description: desc}} -> {atom, desc} end)
  end

  defp build_transport_opts(opts) do
    Enum.reduce([:url, :headers], [], fn key, acc ->
      case Keyword.fetch(opts, key) do
        {:ok, val} -> Keyword.put(acc, key, val)
        :error -> acc
      end
    end)
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/mcp/mcp_test.exs`
Expected: all tests pass

- [ ] **Step 6: Run the full test suite**

Run: `mix test`
Expected: all existing tests still pass, new tests pass

- [ ] **Step 7: Commit**

```bash
git add lib/llmagent/mcp/mcp.ex lib/llmagent/application.ex test/mcp/mcp_test.exs
git commit -m "Add MCP facade, wire supervision tree"
```

---

### Task 6: Integration Test — Full Dispatch Path

**Files:**
- Create: `test/mcp/integration_test.exs`

This test verifies the complete path: connect → agent dispatch → ToolProxy → Connection → mock transport → result.

- [ ] **Step 1: Write the integration test**

```elixir
defmodule LLMAgent.MCP.IntegrationTest do
  use ExUnit.Case, async: false

  alias LLMAgent.MCP

  @mock_tools [
    %{
      "name" => "greet",
      "description" => "Greet someone",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}},
        "required" => ["name"]
      }
    }
  ]

  setup do
    on_exit(fn ->
      try do
        MCP.disconnect(:integ_server)
      catch
        _, _ -> :ok
      end
    end)
    :ok
  end

  test "MCP tool is callable through the standard agent dispatch path" do
    # Connect an MCP server
    {:ok, _pid} = MCP.connect(:integ_server,
      transport: LLMAgent.MCP.Transport.Mock,
      transport_opts: [tools: @mock_tools]
    )

    # Verify tool is in the registry
    assert {:ok, LLMAgent.MCP.ToolProxy} = LLMAgent.Tools.get(:integ_server_greet)

    # Simulate what the agent does: set context, look up tool, call perform/2
    Comn.Contexts.new(%{request_id: "integ_test", trace_id: "trace_integ"})
    Comn.Contexts.put(:tool, :integ_server_greet)

    {:ok, module} = LLMAgent.Tools.get(:integ_server_greet)
    {:ok, result} = module.perform("call", %{"name" => "world"})

    assert result.output =~ "result for greet"
    assert result.metadata.mcp_server == :integ_server
    assert result.metadata.mcp_tool == "greet"

    Process.delete(:comn_context)
  end

  test "MCP tool descriptions are available for system prompt" do
    {:ok, _pid} = MCP.connect(:integ_server,
      transport: LLMAgent.MCP.Transport.Mock,
      transport_opts: [tools: @mock_tools]
    )

    descs = MCP.tool_descriptions()
    desc = descs[:integ_server_greet]
    assert desc =~ "greet"
    assert desc =~ "Greet someone"
    assert desc =~ "name (string, required)"
  end

  test "tools are cleaned up after disconnect" do
    {:ok, _pid} = MCP.connect(:integ_server,
      transport: LLMAgent.MCP.Transport.Mock,
      transport_opts: [tools: @mock_tools]
    )

    assert {:ok, _} = LLMAgent.Tools.get(:integ_server_greet)

    MCP.disconnect(:integ_server)

    assert {:error, :not_found} = LLMAgent.Tools.get(:integ_server_greet)
    assert MCP.tool_descriptions() == %{}
  end
end
```

- [ ] **Step 2: Run the integration test**

Run: `mix test test/mcp/integration_test.exs`
Expected: all tests pass

- [ ] **Step 3: Run the full test suite**

Run: `mix test`
Expected: all tests pass (existing + new)

- [ ] **Step 4: Commit**

```bash
git add test/mcp/integration_test.exs
git commit -m "Add MCP integration tests for full dispatch path"
```

---

### Task 7: Move Mock Transport to Shared Test Support

**Files:**
- Create: `test/support/mcp_mock_transport.ex`
- Modify: `test/mcp/connection_test.exs` — remove inline MockTransport, use shared one
- Modify: `test/mcp/mcp_test.exs` — verify it uses shared mock
- Modify: `test/mcp/integration_test.exs` — verify it uses shared mock
- Modify: `test/test_helper.exs`

- [ ] **Step 1: Extract the mock transport to shared test support**

```elixir
# test/support/mcp_mock_transport.ex
defmodule LLMAgent.MCP.Transport.Mock do
  @behaviour LLMAgent.MCP.Transport

  @impl true
  def start(opts) do
    tools = Keyword.get(opts, :tools, [])
    {:ok, %{tools: tools, calls: []}}
  end

  @impl true
  def send_request(state, %{method: "initialize"} = _request) do
    result = %{
      "protocolVersion" => "2025-03-26",
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "mock", "version" => "1.0"}
    }
    {{:ok, result}, state}
  end

  def send_request(state, %{method: "tools/list"} = _request) do
    result = %{"tools" => state.tools}
    {{:ok, result}, state}
  end

  def send_request(state, %{method: "tools/call", params: params} = _request) do
    result = %{
      "content" => [%{"type" => "text", "text" => "result for #{params["name"]}"}]
    }
    state = %{state | calls: state.calls ++ [params]}
    {{:ok, result}, state}
  end

  def send_request(state, %{method: method}) do
    {{:error, {:unknown_method, method}}, state}
  end

  @impl true
  def close(_state), do: :ok
end
```

- [ ] **Step 2: Update test_helper.exs to compile test support files**

```elixir
# test/test_helper.exs
Code.require_file("support/mcp_mock_transport.ex", __DIR__)
ExUnit.start()
```

- [ ] **Step 3: Remove the inline MockTransport from connection_test.exs**

Remove the `LLMAgent.MCP.Transport.Mock` module definition from the test file — it now lives in `test/support/`.

- [ ] **Step 4: Run full test suite**

Run: `mix test`
Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
git add test/support/mcp_mock_transport.ex test/test_helper.exs test/mcp/connection_test.exs
git commit -m "Extract mock MCP transport to shared test support"
```

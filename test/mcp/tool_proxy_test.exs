defmodule LLMAgent.MCP.ToolProxyTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias LLMAgent.MCP.ToolProxy

  @tool_map_key :llmagent_mcp_tool_map

  setup do
    :persistent_term.put(@tool_map_key, %{})
    on_exit(fn ->
      :persistent_term.put(@tool_map_key, %{})
      Process.delete(:comn_context)
    end)
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
      # Start a mock GenServer that handles {:call_tool, tool, args}
      # It self-registers in init so the key pid is the mock_conn process itself
      {:ok, mock_conn} = GenServer.start_link(LLMAgent.MCP.ToolProxyTest.MockConnection, :test_server)

      # Populate the tool map
      :persistent_term.put(@tool_map_key, %{
        test_server_my_tool: %{connection: :test_server, tool: "my_tool", description: "A test tool"}
      })

      # Set context (what the agent does before dispatching)
      Comn.Contexts.new(%{request_id: "test"})
      Comn.Contexts.put(:tool, :test_server_my_tool)

      {:ok, result} = ToolProxy.perform("call", %{"input" => "value"})
      assert result.output == "mock response"
      assert result.metadata.mcp_server == :test_server
      assert result.metadata.mcp_tool == "my_tool"

      GenServer.stop(mock_conn)
    end

    test "returns error when tool not in map" do
      Comn.Contexts.new(%{request_id: "test"})
      Comn.Contexts.put(:tool, :nonexistent_tool)

      {:error, err} = ToolProxy.perform("call", %{})
      assert err.reason == "mcp_tool_not_found"
    end

    test "returns error when connection process not found" do
      :persistent_term.put(@tool_map_key, %{
        orphan_tool: %{connection: :dead_server, tool: "ghost", description: "Gone"}
      })

      Comn.Contexts.new(%{request_id: "test"})
      Comn.Contexts.put(:tool, :orphan_tool)

      {:error, err} = ToolProxy.perform("call", %{})
      assert err.reason == "mcp_connection_not_found"
    end

    test "returns error when no tool context set" do
      # Don't set any context
      Process.delete(:comn_context)

      {:error, err} = ToolProxy.perform("call", %{})
      assert err.reason == "mcp_proxy_error"
    end
  end

  defmodule MockConnection do
    @moduledoc false
    use GenServer

    def init(server_name) do
      Registry.register(LLMAgent.MCP.Registry, server_name, nil)
      {:ok, %{}}
    end

    def handle_call({:call_tool, _tool, _args}, _from, state) do
      {:reply, {:ok, %{output: "mock response", metadata: %{}}}, state}
    end
  end
end

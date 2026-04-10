defmodule LLMAgent.MCP.Transport.Mock do
  @moduledoc false
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

defmodule LLMAgent.MCP.ConnectionTest do
  @moduledoc false
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

      assert {:ok, LLMAgent.MCP.ToolProxy} = LLMAgent.Tools.get(:test_mcp_create_issue)
      assert {:ok, LLMAgent.MCP.ToolProxy} = LLMAgent.Tools.get(:test_mcp_list_repos)

      tool_map = :persistent_term.get(@tool_map_key, %{})
      assert %{connection: :test_mcp, tool: "create_issue"} = tool_map[:test_mcp_create_issue]
      assert %{connection: :test_mcp, tool: "list_repos"} = tool_map[:test_mcp_list_repos]

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
  end

  describe "info" do
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

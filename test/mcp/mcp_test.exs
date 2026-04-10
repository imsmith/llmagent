defmodule LLMAgent.MCPTest do
  @moduledoc false
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

      MCP.disconnect(:facade_test)
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

defmodule LLMAgent.MCP.IntegrationTest do
  @moduledoc false
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
    {:ok, _pid} = MCP.connect(:integ_server,
      transport: LLMAgent.MCP.Transport.Mock,
      transport_opts: [tools: @mock_tools]
    )

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

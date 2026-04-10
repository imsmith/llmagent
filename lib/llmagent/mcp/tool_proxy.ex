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

  def tool_map, do: :persistent_term.get(@tool_map_key, %{})
end

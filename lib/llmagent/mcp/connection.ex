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
    Process.flag(:trap_exit, true)
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

      tool_map = :persistent_term.get(@tool_map_key, %{})
      updated = Map.put(tool_map, atom, %{
        connection: server_name,
        tool: tool["name"],
        description: description
      })
      :persistent_term.put(@tool_map_key, updated)

      Tools.register(atom, ToolProxy)
      atom
    end)
  end

  defp unregister_tools(server_name, tool_atoms) do
    tool_map = :persistent_term.get(@tool_map_key, %{})
    updated = Map.drop(tool_map, tool_atoms)
    :persistent_term.put(@tool_map_key, updated)

    Enum.each(tool_atoms, fn atom -> Tools.unregister(atom) end)
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
    |> Enum.map(fn {prop_name, spec} ->
      type = spec["type"] || "any"
      req = if prop_name in (required || []), do: "required", else: "optional"
      "  - #{prop_name} (#{type}, #{req})"
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

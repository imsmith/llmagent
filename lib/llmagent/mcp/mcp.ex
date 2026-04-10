defmodule LLMAgent.MCP do
  @moduledoc """
  Public API for managing MCP server connections.

  Facade module — no process. Delegates to ConnectionSupervisor
  for lifecycle and MCP.Registry for lookups.
  """

  alias LLMAgent.MCP.Connection

  @tool_map_key :llmagent_mcp_tool_map

  @doc "Connect to an MCP server by name. Returns `{:ok, pid}` or `{:error, reason}`."
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

  @doc "Disconnect a named MCP connection. Returns `:ok` or `{:error, :not_found}`."
  def disconnect(name) do
    case Registry.lookup(LLMAgent.MCP.Registry, name) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(LLMAgent.MCP.ConnectionSupervisor, pid)

      [] ->
        {:error, :not_found}
    end
  end

  @doc "List all active MCP connections as `{name, pid, info}` tuples."
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

  @doc "Return tool atoms registered for a named connection, or `{:error, :not_found}`."
  def tools_for(name) do
    case Registry.lookup(LLMAgent.MCP.Registry, name) do
      [{pid, _}] ->
        info = GenServer.call(pid, :info)
        info.tools

      [] ->
        {:error, :not_found}
    end
  end

  @doc "Return a map of tool atom => description string for all registered MCP tools."
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

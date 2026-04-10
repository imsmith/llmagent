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

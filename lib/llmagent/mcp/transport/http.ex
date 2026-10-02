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

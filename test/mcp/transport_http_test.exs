defmodule LLMAgent.MCP.Transport.HTTPTest do
  @moduledoc false

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

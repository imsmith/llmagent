defmodule LLMAgent.Tool.Adapter.OpenAIChatTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias LLMAgent.Tool.Adapter.OpenAIChat

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, host: "http://localhost:#{bypass.port}"}
  end

  test "delegates chat to the OpenAI client and returns provenance", %{bypass: bypass, host: host} do
    Bypass.expect_once(bypass, "POST", "/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "stub-model"
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"choices":[{"message":{"content":"hello back"}}]}))
    end)

    payload = %{api_host: host, model: "stub-model"}
    args    = %{messages: [%{"role" => "user", "content" => "hi"}]}

    assert {:ok, "hello back", %{model: "stub-model", latency_ms: latency}} =
             OpenAIChat.generate(payload, "chat", args, [])
    assert is_integer(latency) and latency >= 0
  end

  test "returns an error tuple on http failure", %{bypass: bypass, host: host} do
    Bypass.expect_once(bypass, "POST", "/chat/completions", fn conn ->
      Plug.Conn.resp(conn, 500, ~s({"error":"boom"}))
    end)

    payload = %{api_host: host, model: "stub-model"}
    args    = %{messages: [%{"role" => "user", "content" => "hi"}]}

    assert {:error, {:http_error, 500, _}} =
             OpenAIChat.generate(payload, "chat", args, [])
  end

  test "rejects unknown actions" do
    payload = %{api_host: "http://localhost:1", model: "stub"}
    assert {:error, :unknown_action} =
             OpenAIChat.generate(payload, "speak", %{}, [])
  end
end

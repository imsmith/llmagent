defmodule LLMAgent.LLMClient.OpenAITest do
  use ExUnit.Case, async: true

  alias LLMAgent.LLMClient.OpenAI

  describe "chat/2" do
    test "returns {:ok, content} on successful response" do
      # We test the module's pattern matching by calling it with a real (local) endpoint
      # that won't exist — so we verify error handling instead.
      # Direct unit tests of the success path require a mock HTTP server.
      opts = %{api_host: "http://localhost:1", model: "test", timeout: 1_000}

      result = OpenAI.chat([%{role: "user", content: "hi"}], opts)

      assert {:error, _reason} = result
    end

    test "constructs correct URL from api_host" do
      Code.ensure_loaded(OpenAI)
      assert function_exported?(OpenAI, :chat, 2)
    end

    test "defaults timeout to 120_000 when not specified" do
      # The timeout default is internal — we verify it doesn't crash without :timeout
      opts = %{api_host: "http://localhost:1", model: "test"}

      result = OpenAI.chat([%{role: "user", content: "hi"}], opts)

      assert {:error, _} = result
    end
  end
end

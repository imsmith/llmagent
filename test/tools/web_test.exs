defmodule LLMAgent.Tools.WebTest do
  use ExUnit.Case, async: true
  alias LLMAgent.Tools.Web
  alias LLMAgent.Errors.ErrorStruct

  @httpbin "https://httpbin.org"

  describe "get/2" do
    test "GET with only URL" do
      {:ok, %{"status" => 200, "body" => body}} =
        Web.perform("get", %{"url" => "#{@httpbin}/get"})

      assert is_binary(body)
    end

    test "GET with headers and params" do
      {:ok, %{"status" => 200, "body" => body}} =
        Web.perform("get", %{
          "url" => "#{@httpbin}/get",
          "headers" => %{"User-Agent" => "LLMAgentTest"},
          "params" => %{"foo" => "bar"}
        })

      assert is_binary(body)
      assert body =~ "foo"
    end

    test "GET with invalid URL returns error" do
      {:error, %ErrorStruct{reason: "http_error"}} =
        Web.perform("get", %{"url" => "not-a-valid-url"})
    end

    test "GET with missing URL returns error" do
      assert {:error, %ErrorStruct{reason: "http_error"}} =
               Web.perform("get", %{})
    end
  end

  describe "post/2" do
    test "POST with valid JSON body" do
      {:ok, %{"status" => 200, "body" => body}} =
        Web.perform("post", %{
          "url" => "#{@httpbin}/post",
          "body" => %{"key" => "value"}
        })

      assert body =~ "key"
    end

    test "POST with headers and body" do
      {:ok, %{"status" => 200, "body" => body}} =
        Web.perform("post", %{
          "url" => "#{@httpbin}/post",
          "headers" => %{"Content-Type" => "application/json"},
          "body" => %{"data" => "test"}
        })

      assert body =~ "data"
    end

    test "POST with missing URL returns error" do
      assert {:error, %ErrorStruct{reason: "http_error"}} =
               Web.perform("post", %{"body" => %{"foo" => "bar"}})
    end
  end

  describe "simulate_browser/2" do
    test "returns mock message with URL" do
      {:ok, result} = Web.perform("simulate_browser", %{"url" => "https://example.com"})
      assert result =~ "simulate visiting"
    end

    test "simulate_browser with no URL still returns" do
      {:ok, result} = Web.perform("simulate_browser", %{})
      assert is_binary(result)
    end
  end

  describe "unknown command" do
    test "returns error struct for unsupported action" do
      {:error, %ErrorStruct{reason: "unknown_command"}} =
        Web.perform("zoom_and_enhance", %{"url" => "https://example.com"})
    end
  end
end

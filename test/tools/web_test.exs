defmodule LLMAgent.Tools.WebTest do
  use ExUnit.Case, async: true
  alias LLMAgent.Tools.Web
  alias Comn.Errors.ErrorStruct

  @httpbin "https://httpbin.org"

  describe "get/2" do
    @tag :integration
    test "GET with only URL" do
      {:ok, %{output: body, metadata: %{status: 200}}} =
        Web.perform("get", %{"url" => "#{@httpbin}/get"})

      assert is_map(body)
    end

    @tag :integration
    test "GET with headers and params" do
      {:ok, %{output: body, metadata: %{status: 200}}} =
        Web.perform("get", %{
          "url" => "#{@httpbin}/get",
          "headers" => %{"User-Agent" => "LLMAgentTest"},
          "params" => %{"foo" => "bar"}
        })

      assert is_map(body)
      assert body["args"]["foo"] == "bar"
    end

    test "GET with invalid URL returns error" do
      {:error, %ErrorStruct{reason: "http_error"}} =
        Web.perform("get", %{"url" => "not-a-valid-url"})
    end

    test "GET with missing URL returns error" do
      assert {:error, %ErrorStruct{reason: "unknown_command"}} =
               Web.perform("get", %{})
    end
  end

  describe "post/2" do
    @tag :integration
    test "POST with valid JSON body" do
      {:ok, %{output: body, metadata: %{status: 200}}} =
        Web.perform("post", %{
          "url" => "#{@httpbin}/post",
          "body" => %{"key" => "value"}
        })

      assert is_map(body)
    end

    @tag :integration
    test "POST with headers and body" do
      {:ok, %{output: body, metadata: %{status: 200}}} =
        Web.perform("post", %{
          "url" => "#{@httpbin}/post",
          "headers" => %{"Content-Type" => "application/json"},
          "body" => %{"data" => "test"}
        })

      assert is_map(body)
    end

    test "POST with missing URL returns error" do
      assert {:error, %ErrorStruct{reason: "unknown_command"}} =
               Web.perform("post", %{"body" => %{"foo" => "bar"}})
    end
  end

  describe "unknown command" do
    test "returns error struct for unsupported action" do
      {:error, %ErrorStruct{reason: "unknown_command"}} =
        Web.perform("zoom_and_enhance", %{"url" => "https://example.com"})
    end
  end
end

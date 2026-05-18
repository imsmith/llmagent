defmodule LLMAgent.Tools.WebTest do
  @moduledoc false
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

  describe "tool-discovery substrate (via Dispatcher)" do
    # Bypass opens a real local TCP port so Req.get/post hit it without
    # modifying perform/2.  async: false is required by Bypass.
    use ExUnit.Case, async: false
    alias LLMAgent.{Tools.Web, Tools.Discovery, Tool.Dispatcher, Tool.Policy}

    setup do
      case Process.whereis(Discovery) do
        nil -> {:ok, _} = Discovery.start_link(consume_announcements: false)
        _ -> Discovery.reset!()
      end

      LLMAgent.Tool.Bindings.init_registry()
      LLMAgent.Tool.Kinds.init_registry()
      :ok = Discovery.register(Web.ad())

      bypass = Bypass.open()
      {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
    end

    test "ad/0 declares :query and :action with coordinate function.http" do
      ad = Web.ad()
      assert ad.coordinate == "function.http"
      assert :query in ad.kinds
      assert :action in ad.kinds
    end

    test "dispatcher.query/4 get dispatches", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/hello", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.resp(200, "pong")
      end)

      policy = %Policy{
        allow: [%{coordinate: "function.http", kinds: [:query], actions: ["get"]}],
        fidelity_min: :authoritative
      }

      assert {:ok, _value, _meta} =
               Dispatcher.query("function.http", "get",
                 %{"url" => "#{base_url}/hello"}, policy: policy)
    end

    test "dispatcher.act/5 post dispatches", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "POST", "/submit", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, ~s({"ok":true}))
      end)

      policy = %Policy{
        allow: [%{coordinate: "function.http", kinds: [:action], actions: ["post"]}],
        fidelity_min: :authoritative
      }

      assert {:ok, _ack, _meta} =
               Dispatcher.act("function.http", "post",
                 %{"url" => "#{base_url}/submit", "body" => %{"x" => 1}},
                 nil, policy: policy)
    end
  end
end

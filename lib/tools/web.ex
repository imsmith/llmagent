defmodule LLMAgent.Tools.Web do
  @moduledoc """
  Provides tools for making HTTP requests.

  Supported actions:
    - `"get"`: Perform an HTTP GET request
    - `"post"`: Perform an HTTP POST request (with body)

  Required input:
    - `"url"`: the full URL to fetch

  Optional input:
    - `"headers"`: map of request headers
    - `"params"`: query string parameters for GET
    - `"body"`: for POST, a map or string payload
  """

  @behaviour LLMAgent.Tool
  @behaviour LLMAgent.Tool.Kinds.Query
  @behaviour LLMAgent.Tool.Kinds.Action
  alias Comn.Errors.ErrorStruct

  @doc """
  Returns a human-readable description of the Web tool.

  ## Examples

      iex> LLMAgent.Tools.Web.describe()
      ...> |> is_binary()
      true
  """
  @impl true
  def describe do
    """
    Handles HTTP API requests.

    - `get`: fetch a URL using HTTP GET
    - `post`: send data via HTTP POST

    Required:
      - `url`: the full URL to fetch

    Optional:
      - `headers`: map of headers
      - `params`: for GET requests
      - `body`: for POST requests (raw string or JSON map)
    """
  end

  @doc "Authoritative tool ad."
  @impl LLMAgent.Tool
  @spec ad() :: LLMAgent.ToolAd.t()
  def ad do
    LLMAgent.ToolAd.new(%{
      id: "builtin.web",
      coordinate: "function.http",
      kinds: [:query, :action],
      binding: {:module, __MODULE__},
      operational: %{
        actions: %{
          "get"  => %{inputs: %{}, outputs: %{}, pre: nil, post: nil},
          "post" => %{inputs: %{}, outputs: %{}, pre: nil, post: nil}
        }
      },
      constraint: %{
        idempotency: %{"get" => :idempotent, "post" => :non_idempotent},
        blast_radius: %{"get" => :external, "post" => :external}
      },
      affordance: %{
        declared: [%{
          intent: "HTTP requests against arbitrary URLs",
          suits: "fetching/posting JSON/text payloads",
          avoid_when: "the target is on a local socket — use a more specific tool"
        }],
        learned: [],
        open: false
      },
      fidelity: :authoritative,
      provenance: %{source: "llmagent.builtin", produced_at: ~U[2026-05-18 00:00:00Z], based_on: [], signature: nil},
      lease: :permanent,
      meta: %{}
    })
  end

  @impl LLMAgent.Tool.Kinds.Query
  def query("get", args) do
    case perform("get", args) do
      {:ok, %{output: out, metadata: meta}} -> {:ok, out, meta}
      {:error, _} = err -> err
    end
  end

  def query(_, _), do: {:error, :unknown_action}

  @impl LLMAgent.Tool.Kinds.Action
  def act(action, args, _idempotency_key) when action in ["post"] do
    case perform(action, args) do
      {:ok, %{output: out, metadata: meta}} -> {:ok, out, meta}
      {:error, _} = err -> err
    end
  end

  def act(_, _, _), do: {:error, :unknown_action}

  @doc ~S"""
  Perform an HTTP action.

  ## Examples

      # GET request
      {:ok, %{output: body, metadata: %{status: 200, url: url}}} =
        LLMAgent.Tools.Web.perform("get", %{"url" => "https://httpbin.org/get"})

      # POST request with JSON body
      LLMAgent.Tools.Web.perform("post", %{
        "url" => "https://httpbin.org/post",
        "body" => %{"key" => "value"},
        "headers" => %{"content-type" => "application/json"}
      })

  Unknown action returns error:

      iex> {:error, %Comn.Errors.ErrorStruct{reason: "unknown_command"}} =
      ...>   LLMAgent.Tools.Web.perform("nope", %{})
  """
  @impl true
  def perform("get", %{"url" => url} = args) do
    opts = base_opts(url, args)
    Req.get(opts)
    |> normalize_response(url)
  rescue
    e in Mint.TransportError -> {:error, ErrorStruct.new("http_error", "url", Exception.message(e))}
    e in Mint.HTTPError -> {:error, ErrorStruct.new("http_error", "url", Exception.message(e))}
    e in ArgumentError -> {:error, ErrorStruct.new("http_error", "url", Exception.message(e))}
  end

  def perform("post", %{"url" => url} = args) do
    body = Map.get(args, "body", "")
    encoded_body = if is_map(body), do: Jason.encode!(body), else: body
    opts = base_opts(url, args) |> Keyword.put(:body, encoded_body)
    Req.post(opts)
    |> normalize_response(url)
  rescue
    e in Mint.TransportError -> {:error, ErrorStruct.new("http_error", "url", Exception.message(e))}
    e in Mint.HTTPError -> {:error, ErrorStruct.new("http_error", "url", Exception.message(e))}
    e in Jason.EncodeError -> {:error, ErrorStruct.new("http_error", "url", Exception.message(e))}
    e in ArgumentError -> {:error, ErrorStruct.new("http_error", "url", Exception.message(e))}
  end

  def perform(_, _), do:
    {:error, ErrorStruct.new("unknown_command", nil, "Unrecognized action.")}

  defp base_opts(url, args) do
    []
    |> Keyword.put(:url, url)
    |> maybe_add(:headers, args)
    |> maybe_add(:params, args)
  end

  defp maybe_add(opts, key, args) do
    case Map.get(args, to_string(key)) do
      nil -> opts
      value -> Keyword.put(opts, key, value)
    end
  end

  defp normalize_response({:ok, %Req.Response{status: status, body: body}}, url) do
    {:ok, %{output: body, metadata: %{status: status, url: url}}}
  end

  defp normalize_response({:error, error}, _url) do
    {:error, ErrorStruct.new("http_error", "url", Exception.message(error))}
  end
end

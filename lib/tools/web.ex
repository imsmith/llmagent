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
  alias Comn.Errors.ErrorStruct

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

  @impl true
  def perform("get", %{"url" => url} = args) do
    opts = base_opts(url, args)
    Req.get(opts)
    |> normalize_response(url)
  rescue
    e -> {:error, ErrorStruct.new("http_error", "url", Exception.message(e))}
  end

  def perform("post", %{"url" => url} = args) do
    body = Map.get(args, "body", "")
    encoded_body = if is_map(body), do: Jason.encode!(body), else: body
    opts = base_opts(url, args) |> Keyword.put(:body, encoded_body)
    Req.post(opts)
    |> normalize_response(url)
  rescue
    e -> {:error, ErrorStruct.new("http_error", "url", Exception.message(e))}
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

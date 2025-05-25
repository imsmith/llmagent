defmodule LLMAgent.Tools.Web do
  @moduledoc """
  Provides tools for making HTTP requests and simulating a web browser.

  Supported actions:
    - `"get"`: Perform an HTTP GET request
    - `"post"`: Perform an HTTP POST request (with body)
    - `"simulate_browser"`: Placeholder for headless browser simulation

  Optional input:
    - `"headers"`: map of request headers
    - `"params"`: query string parameters for GET
    - `"body"`: for POST, a map or string payload
  """

  @behaviour LLMAgent.Tool

  @impl true
  def describe do
    """
    Handles HTTP API requests and simulates web browsing.

    - `get`: fetch a URL using HTTP GET
    - `post`: send data via HTTP POST
    - `simulate_browser`: placeholder for headless browsing

    Required:
      - `url`: the full URL to fetch

    Optional:
      - `headers`: map of headers (e.g., `"User-Agent" => "Agent"`)
      - `params`: for GET requests
      - `body`: for POST requests (raw string or JSON)
    """
  end

  @impl true
  def perform("get", %{"url" => url} = args) do
    opts = base_opts(url, args)
    Req.get(opts)
    |> normalize_response()
  end

  def perform("post", %{"url" => url} = args) do
    opts = base_opts(url, args)
    opts = Keyword.put(opts, :body, Map.get(args, "body", ""))
    Req.post(opts)
    |> normalize_response()
  end

  def perform("simulate_browser", %{"url" => url}) do
    {:ok, "Would simulate visiting #{url} in a headless browser"}
  end

  def perform(_, _), do:
    {:error, LLMAgent.Errors.ErrorStruct.new("unknown_command", nil, "Unrecognized action.")}

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

  defp normalize_response({:ok, %Req.Response{status: status, body: body}}) do
    {:ok, %{"status" => status, "body" => body}}
  end

  defp normalize_response({:error, error}) do
    {:error,
     %LLMAgent.Errors.ErrorStruct{
       reason: "http_error",
       message: Exception.message(error)
     }}
  end
end

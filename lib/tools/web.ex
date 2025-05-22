defmodule LLMAgent.Tools.Web do
  @moduledoc "Provides tools for making HTTP requests and simulating a web browser."
  @behaviour LLMAgent.Tool

  @impl true
  def describe do
    "Handles HTTP API requests and simulates web browsing."
  end

  @impl true
  def perform("get", %{"url" => url}) do
    Req.get(url)
  end

  def perform("post", %{"url" => url, "body" => body}) do
    Req.post(url, body: body)
  end

  def perform("simulate_browser", %{"url" => url}) do
    {:ok, "Would simulate visiting #{url} in a headless browser"}
  end

  def perform(_, _), do: {:error, :unknown_command}
end

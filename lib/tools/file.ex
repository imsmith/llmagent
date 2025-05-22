defmodule LLMAgent.Tools.File do
  @moduledoc "Provides file system operations like reading and writing files."
  @behaviour LLMAgent.Tool

  @impl true
  def describe do
    "Performs basic file operations (read/write/delete)."
  end

  @impl true
  def perform("read", %{"path" => path}) do
    File.read(path)
  end

  def perform("write", %{"path" => path, "content" => content}) do
    File.write(path, content)
  end

  def perform("delete", %{"path" => path}) do
    File.rm(path)
  end

  def perform(_, _), do: {:error, :unknown_command}
end

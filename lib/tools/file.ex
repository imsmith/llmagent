defmodule LLMAgent.Tools.File do
  @moduledoc "Provides file system operations like reading, writing, and deleting files."
  @behaviour LLMAgent.Tool
  alias Comn.Errors.ErrorStruct

  @impl true
  def describe do
    "Performs basic file operations (read/write/delete)."
  end

  @impl true
  def perform("read", %{"path" => path}) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, %{output: content, metadata: %{path: path, size: byte_size(content)}}}

      {:error, reason} ->
        {:error, ErrorStruct.new("file_error", "path", "Cannot read #{path}: #{reason}")}
    end
  end

  def perform("write", %{"path" => path, "content" => content}) do
    case File.write(path, content) do
      :ok ->
        {:ok, %{output: :ok, metadata: %{path: path, bytes_written: byte_size(content)}}}

      {:error, reason} ->
        {:error, ErrorStruct.new("file_error", "path", "Cannot write #{path}: #{reason}")}
    end
  end

  def perform("delete", %{"path" => path}) do
    case File.rm(path) do
      :ok ->
        {:ok, %{output: :ok, metadata: %{path: path}}}

      {:error, reason} ->
        {:error, ErrorStruct.new("file_error", "path", "Cannot delete #{path}: #{reason}")}
    end
  end

  def perform(_, _),
    do: {:error, ErrorStruct.new("unknown_command", nil, "Unrecognized File action")}
end

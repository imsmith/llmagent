defmodule LLMAgent.Tools.File do
  @moduledoc "Provides file system operations like reading, writing, and deleting files."
  @behaviour LLMAgent.Tool
  @behaviour LLMAgent.Tool.Kinds.Query
  @behaviour LLMAgent.Tool.Kinds.Action
  alias Comn.Errors.ErrorStruct

  @doc """
  Returns a human-readable description of the File tool.

  ## Examples

      iex> LLMAgent.Tools.File.describe()
      "Performs basic file operations (read/write/delete)."
  """
  @impl true
  def describe do
    "Performs basic file operations (read/write/delete)."
  end

  @doc "Authoritative tool ad."
  @spec ad() :: LLMAgent.ToolAd.t()
  def ad do
    LLMAgent.ToolAd.new(%{
      id: "builtin.file",
      coordinate: "resource.fs.file",
      kinds: [:query, :action],
      binding: {:module, __MODULE__},
      operational: %{
        actions: %{
          "read"   => %{inputs: %{}, outputs: %{}, pre: nil, post: nil},
          "write"  => %{inputs: %{}, outputs: %{}, pre: nil, post: nil},
          "delete" => %{inputs: %{}, outputs: %{}, pre: nil, post: nil}
        }
      },
      constraint: %{
        idempotency: %{"read" => :idempotent, "write" => :non_idempotent, "delete" => :non_idempotent},
        blast_radius: %{"read" => :local, "write" => :local, "delete" => :local}
      },
      affordance: %{
        declared: [%{
          intent: "read/write/delete files",
          suits: "any file IO",
          avoid_when: "the path is on a remote mount with high latency"
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
  def query("read", args) do
    case perform("read", args) do
      {:ok, %{output: out, metadata: meta}} -> {:ok, out, meta}
      {:error, _} = err -> err
    end
  end

  def query(_, _), do: {:error, :unknown_action}

  @impl LLMAgent.Tool.Kinds.Action
  def act(action, args, _idempotency_key) when action in ["write", "delete"] do
    case perform(action, args) do
      {:ok, %{output: out, metadata: meta}} -> {:ok, out, meta}
      {:error, _} = err -> err
    end
  end

  def act(_, _, _), do: {:error, :unknown_action}

  @doc """
  Perform a file action.

  ## Examples

  Write and read back:

      iex> path = Path.join(System.tmp_dir!(), "doctest_file_#{System.unique_integer([:positive])}")
      iex> {:ok, %{output: :ok, metadata: %{bytes_written: 5}}} =
      ...>   LLMAgent.Tools.File.perform("write", %{"path" => path, "content" => "hello"})
      iex> {:ok, %{output: "hello", metadata: %{size: 5}}} =
      ...>   LLMAgent.Tools.File.perform("read", %{"path" => path})
      iex> File.rm(path)

  Read nonexistent file:

      iex> {:error, %Comn.Errors.ErrorStruct{reason: "file_error"}} =
      ...>   LLMAgent.Tools.File.perform("read", %{"path" => "/no/such/file"})

  Unknown action:

      iex> {:error, %Comn.Errors.ErrorStruct{reason: "unknown_command"}} =
      ...>   LLMAgent.Tools.File.perform("nope", %{})
  """
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

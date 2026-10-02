defmodule LLMAgent.Tools.TupleSpace do
  @moduledoc """
  JSON-aware adapter over `LLMAgent.TupleSpace`.

  Tuples and patterns arrive as JSON arrays from the LLM and are converted to
  Erlang tuples. The string `"_"` in a pattern is mapped to the atom `:_`
  (wildcard). Results are converted back to JSON-friendly lists on egress.
  """

  @behaviour LLMAgent.Tool
  @behaviour LLMAgent.Tool.Kinds.Query
  @behaviour LLMAgent.Tool.Kinds.Action
  alias LLMAgent.TupleSpace, as: TS
  alias Comn.Errors.ErrorStruct

  @doc "Authoritative tool ad."
  @impl true
  @spec ad() :: LLMAgent.ToolAd.t()
  def ad do
    LLMAgent.ToolAd.new(%{
      id: "builtin.tuplespace",
      coordinate: "function.coordination.tuplespace",
      kinds: [:query, :action],
      binding: {:module, __MODULE__},
      operational: %{
        actions: %{
          "read"          => %{inputs: %{}, outputs: %{}, pre: nil, post: nil},
          "read_nowait"   => %{inputs: %{}, outputs: %{}, pre: nil, post: nil},
          "list_spaces"   => %{inputs: %{}, outputs: %{}, pre: nil, post: nil},
          "write"         => %{inputs: %{}, outputs: %{}, pre: nil, post: nil},
          "take"          => %{inputs: %{}, outputs: %{}, pre: nil, post: nil},
          "take_nowait"   => %{inputs: %{}, outputs: %{}, pre: nil, post: nil},
          "create_space"  => %{inputs: %{}, outputs: %{}, pre: nil, post: nil},
          "destroy_space" => %{inputs: %{}, outputs: %{}, pre: nil, post: nil}
        }
      },
      constraint: %{
        idempotency: %{
          "read"          => :idempotent,
          "read_nowait"   => :idempotent,
          "list_spaces"   => :idempotent,
          "write"         => :non_idempotent,
          "take"          => :non_idempotent,
          "take_nowait"   => :non_idempotent,
          "create_space"  => :non_idempotent,
          "destroy_space" => :non_idempotent
        },
        blast_radius: %{
          "read"          => :local,
          "read_nowait"   => :local,
          "list_spaces"   => :local,
          "write"         => :local,
          "take"          => :local,
          "take_nowait"   => :local,
          "create_space"  => :local,
          "destroy_space" => :local
        }
      },
      affordance: %{
        declared: [
          %{
            intent: "Linda-style coordination via shared tuples",
            suits: "loosely-coupled multi-agent message passing",
            avoid_when:
              "you need ordered delivery or persistent state — use a real queue/db"
          }
        ],
        learned: [],
        open: false
      },
      fidelity: :authoritative,
      provenance: %{
        source: "llmagent.builtin",
        produced_at: ~U[2026-05-18 00:00:00Z],
        based_on: [],
        signature: nil
      },
      lease: :permanent,
      meta: %{}
    })
  end

  @impl LLMAgent.Tool.Kinds.Query
  def query(action, args) when action in ["read", "read_nowait", "list_spaces"] do
    case perform(action, args) do
      {:ok, %{output: out, metadata: meta}} -> {:ok, out, meta}
      {:error, _} = err -> err
    end
  end

  def query(_, _), do: {:error, :unknown_action}

  @impl LLMAgent.Tool.Kinds.Action
  def act(action, args, _idempotency_key)
      when action in ["write", "take", "take_nowait", "create_space", "destroy_space"] do
    case perform(action, args) do
      {:ok, %{output: out, metadata: meta}} -> {:ok, out, meta}
      {:error, _} = err -> err
    end
  end

  def act(_, _, _), do: {:error, :unknown_action}

  @impl true
  def describe do
    """
    Coordination via Linda-style tuple spaces. Tuples and patterns are JSON arrays.
    Use the string "_" inside a pattern as a wildcard.

    Actions:
      - write {space, tuple}: write a tuple. Returns "ok".
        Example: {"tool":"tuple_space","action":"write","args":{"space":"default","tuple":["task","worker","go"]}}
      - read {space, pattern, timeout}: blocking non-destructive read (ms). Returns the matched tuple as an array.
      - take {space, pattern, timeout}: blocking destructive read.
      - read_nowait {space, pattern}: non-blocking peek.
      - take_nowait {space, pattern}: non-blocking consume.
      - list_spaces {}: list all running space names.
      - create_space {name}: start a named space.
      - destroy_space {name}: stop a named space.
    """
  end

  @impl true
  def perform("write", %{"space" => space, "tuple" => tuple}) when is_list(tuple) do
    case TS.out(space_name(space), encode_tuple(tuple)) do
      :ok -> {:ok, %{output: "ok", metadata: %{action: "write"}}}
      {:error, reason} -> ts_error(reason)
    end
  end

  def perform("read", %{"space" => space, "pattern" => pattern, "timeout" => timeout})
      when is_list(pattern) and is_integer(timeout) do
    case TS.rd(space_name(space), encode_tuple(pattern), timeout) do
      {:ok, tuple} -> {:ok, %{output: decode_tuple(tuple), metadata: %{action: "read"}}}
      {:error, reason} -> ts_error(reason)
    end
  end

  def perform("take", %{"space" => space, "pattern" => pattern, "timeout" => timeout})
      when is_list(pattern) and is_integer(timeout) do
    case TS.in_(space_name(space), encode_tuple(pattern), timeout) do
      {:ok, tuple} -> {:ok, %{output: decode_tuple(tuple), metadata: %{action: "take"}}}
      {:error, reason} -> ts_error(reason)
    end
  end

  def perform("read_nowait", %{"space" => space, "pattern" => pattern}) when is_list(pattern) do
    case TS.rd_nowait(space_name(space), encode_tuple(pattern)) do
      {:ok, tuple} -> {:ok, %{output: decode_tuple(tuple), metadata: %{action: "read_nowait"}}}
      {:error, reason} -> ts_error(reason)
    end
  end

  def perform("take_nowait", %{"space" => space, "pattern" => pattern}) when is_list(pattern) do
    case TS.in_nowait(space_name(space), encode_tuple(pattern)) do
      {:ok, tuple} -> {:ok, %{output: decode_tuple(tuple), metadata: %{action: "take_nowait"}}}
      {:error, reason} -> ts_error(reason)
    end
  end

  def perform("list_spaces", _args) do
    spaces = TS.list_spaces() |> Enum.map(&Atom.to_string/1)
    {:ok, %{output: spaces, metadata: %{action: "list_spaces"}}}
  end

  def perform("create_space", %{"name" => name}) when is_binary(name) do
    case TS.start_space(space_name(name)) do
      {:ok, _pid} ->
        {:ok, %{output: "ok", metadata: %{action: "create_space"}}}

      {:error, {:already_started, _}} ->
        {:error, ErrorStruct.new("already_started", "name", "Space #{name} is already running")}

      {:error, reason} ->
        ts_error(reason)
    end
  end

  def perform("destroy_space", %{"name" => name}) when is_binary(name) do
    case TS.stop_space(space_name(name)) do
      :ok ->
        {:ok, %{output: "ok", metadata: %{action: "destroy_space"}}}

      {:error, :not_found} ->
        {:error, ErrorStruct.new("not_found", "name", "Space #{name} not found")}

      {:error, reason} ->
        ts_error(reason)
    end
  end

  def perform(_, _),
    do: {:error, ErrorStruct.new("unknown_command", nil, "Unrecognized TupleSpace action")}

  ## Encoding helpers

  defp space_name(name) when is_atom(name), do: name
  defp space_name(name) when is_binary(name), do: String.to_atom(name)

  defp encode_tuple(list) when is_list(list) do
    list
    |> Enum.map(&encode_elem/1)
    |> List.to_tuple()
  end

  defp encode_elem("_"), do: :_
  defp encode_elem(other), do: other

  defp decode_tuple(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&decode_elem/1)
  end

  defp decode_elem(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp decode_elem(other), do: other

  ## Error mapping

  defp ts_error(:timeout), do: {:error, ErrorStruct.new("timeout", nil, "operation timed out")}
  defp ts_error(:no_match), do: {:error, ErrorStruct.new("no_match", nil, "no matching tuple")}

  defp ts_error(:space_not_found),
    do: {:error, ErrorStruct.new("space_not_found", "space", "tuple space not found")}

  defp ts_error(other),
    do: {:error, ErrorStruct.new("tuple_space_error", nil, inspect(other))}
end

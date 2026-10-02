defmodule LLMAgent.TupleSpace do
  @moduledoc """
  Public API for Linda-style tuple space coordination.

  Provides `out` (write), `in_` (blocking destructive read), `rd` (blocking
  non-destructive read), and non-blocking variants. Operations default to
  the `:default` space; pass a space name as the first argument for others.

  ## Examples

      iex> :ok = LLMAgent.TupleSpace.out({:greeting, "hello"})
      iex> {:ok, {:greeting, "hello"}} = LLMAgent.TupleSpace.in_nowait({:greeting, :_})
  """

  alias LLMAgent.TupleSpace.{Space, Pattern}

  ## Space Management

  @doc """
  Start a named tuple space under the DynamicSupervisor.

  ## Examples

      iex> {:ok, pid} = LLMAgent.TupleSpace.start_space(:doctest_ts)
      iex> is_pid(pid)
      true
      iex> LLMAgent.TupleSpace.stop_space(:doctest_ts)
      :ok
  """
  def start_space(name) do
    DynamicSupervisor.start_child(
      LLMAgent.TupleSpace.Supervisor,
      {Space, name: name}
    )
  end

  @doc """
  Stop a named tuple space.

  ## Examples

      iex> LLMAgent.TupleSpace.stop_space(:nonexistent_doctest_space)
      {:error, :not_found}
  """
  def stop_space(name) do
    case lookup(name) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(LLMAgent.TupleSpace.Supervisor, pid)
      {:error, :space_not_found} -> {:error, :not_found}
    end
  end

  @doc """
  List all running space names.

  ## Examples

      iex> is_list(LLMAgent.TupleSpace.list_spaces())
      true
  """
  def list_spaces do
    LLMAgent.TupleSpace.Supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn {_, pid, _, _} ->
      if is_pid(pid) do
        try do
          [Space.info(pid).name]
        catch
          :exit, _ -> []
        end
      else
        []
      end
    end)
  end

  ## Linda Operations — default space overloads

  @doc """
  Write a tuple into the default space.

  ## Examples

      iex> :ok = LLMAgent.TupleSpace.out({:doctest, "hello"})
      iex> {:ok, {:doctest, "hello"}} = LLMAgent.TupleSpace.in_nowait({:doctest, :_})
  """
  def out(tuple) when is_tuple(tuple), do: out(:default, tuple)

  @doc "Blocking destructive read from the default space. Blocks until match or timeout."
  def in_(pattern, timeout), do: in_(:default, pattern, timeout)

  @doc "Blocking non-destructive read from the default space. Blocks until match or timeout."
  def rd(pattern, timeout), do: rd(:default, pattern, timeout)

  @doc "Non-blocking destructive read from the default space. Returns immediately."
  def in_nowait(pattern), do: in_nowait(:default, pattern)

  @doc "Non-blocking non-destructive read from the default space. Returns immediately."
  def rd_nowait(pattern), do: rd_nowait(:default, pattern)

  ## Linda Operations — named space

  @doc "Write a tuple into the named space."
  def out(space, tuple) when is_tuple(tuple) do
    case lookup(space) do
      {:ok, pid} -> Space.out(pid, tuple)
      {:error, _} = err -> err
    end
  end

  @doc "Blocking destructive read from the named space."
  def in_(space, pattern, timeout) do
    case Pattern.compile(pattern) do
      {:error, _} = err -> err
      {:ok, _} ->
        case lookup(space) do
          {:ok, pid} -> Space.in_(pid, pattern, timeout)
          {:error, _} = err -> err
        end
    end
  end

  @doc "Blocking non-destructive read from the named space."
  def rd(space, pattern, timeout) do
    case Pattern.compile(pattern) do
      {:error, _} = err -> err
      {:ok, _} ->
        case lookup(space) do
          {:ok, pid} -> Space.rd(pid, pattern, timeout)
          {:error, _} = err -> err
        end
    end
  end

  @doc "Non-blocking destructive read from the named space."
  def in_nowait(space, pattern) do
    case Pattern.compile(pattern) do
      {:error, _} = err -> err
      {:ok, _} ->
        case lookup(space) do
          {:ok, pid} -> Space.in_nowait(pid, pattern)
          {:error, _} = err -> err
        end
    end
  end

  @doc """
  Non-blocking non-destructive read from the named space.

  ## Examples

      iex> LLMAgent.TupleSpace.rd_nowait(:nonexistent_doctest_space, {:a, :_})
      {:error, :space_not_found}
  """
  def rd_nowait(space, pattern) do
    case Pattern.compile(pattern) do
      {:error, _} = err -> err
      {:ok, spec} ->
        table = :"llmagent_ts_#{space}"
        match_pattern = spec |> hd() |> elem(0)

        try do
          case :ets.match_object(table, match_pattern) do
            [first | _] -> {:ok, first}
            [] -> {:error, :no_match}
          end
        rescue
          ArgumentError -> {:error, :space_not_found}
        end
    end
  end

  ## Private

  defp lookup(name) do
    case Registry.lookup(LLMAgent.TupleSpace.Registry, name) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :space_not_found}
    end
  end
end

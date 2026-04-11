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

  def start_space(name) do
    DynamicSupervisor.start_child(
      LLMAgent.TupleSpace.Supervisor,
      {Space, name: name}
    )
  end

  def stop_space(name) do
    case lookup(name) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(LLMAgent.TupleSpace.Supervisor, pid)
      {:error, :space_not_found} -> {:error, :not_found}
    end
  end

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

  def out(tuple) when is_tuple(tuple), do: out(:default, tuple)
  def in_(pattern, timeout), do: in_(:default, pattern, timeout)
  def rd(pattern, timeout), do: rd(:default, pattern, timeout)
  def in_nowait(pattern), do: in_nowait(:default, pattern)
  def rd_nowait(pattern), do: rd_nowait(:default, pattern)

  ## Linda Operations — named space

  def out(space, tuple) when is_tuple(tuple) do
    case lookup(space) do
      {:ok, pid} -> Space.out(pid, tuple)
      {:error, _} = err -> err
    end
  end

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

defmodule LLMAgent.TupleSpace.Pattern do
  @moduledoc """
  Compiles Elixir-friendly tuple patterns into ETS match specs.

  Patterns are tuples where `:_` matches any value in that position
  and all other values are literal matches.

  ## Examples

      iex> {:ok, spec} = LLMAgent.TupleSpace.Pattern.compile({:task, :pending, :_})
      iex> is_list(spec)
      true

      iex> LLMAgent.TupleSpace.Pattern.compile("not a tuple")
      {:error, :invalid_pattern}

      iex> LLMAgent.TupleSpace.Pattern.match?({:task, :_, :_}, {:task, :pending, "build"})
      true

      iex> LLMAgent.TupleSpace.Pattern.match?({:task, :done, :_}, {:task, :pending, "build"})
      false
  """

  @spec compile(tuple()) :: {:ok, list()} | {:error, :invalid_pattern}
  def compile(pattern) when is_tuple(pattern) do
    {:ok, [{pattern, [], [:"$_"]}]}
  end

  def compile(_), do: {:error, :invalid_pattern}

  @spec match?(pattern :: tuple(), tuple :: tuple()) :: boolean()
  def match?(pattern, tuple) when is_tuple(pattern) and is_tuple(tuple) do
    if tuple_size(pattern) != tuple_size(tuple) do
      false
    else
      pattern_list = Tuple.to_list(pattern)
      tuple_list = Tuple.to_list(tuple)

      Enum.zip(pattern_list, tuple_list)
      |> Enum.all?(fn
        {:_, _} -> true
        {a, b} -> a == b
      end)
    end
  end

  def match?(_, _), do: false
end

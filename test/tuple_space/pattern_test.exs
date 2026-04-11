defmodule LLMAgent.TupleSpace.PatternTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias LLMAgent.TupleSpace.Pattern

  describe "compile/1" do
    test "compiles a tuple with no wildcards" do
      {:ok, spec} = Pattern.compile({:task, :pending, "build"})
      assert is_list(spec)
      assert length(spec) == 1
    end

    test "compiles a tuple with :_ wildcards" do
      {:ok, spec} = Pattern.compile({:task, :_, :_})
      assert is_list(spec)
    end

    test "compiles a single-element tuple" do
      {:ok, spec} = Pattern.compile({:ping})
      assert is_list(spec)
    end

    test "returns error for non-tuple input" do
      assert {:error, :invalid_pattern} = Pattern.compile("not a tuple")
      assert {:error, :invalid_pattern} = Pattern.compile(42)
      assert {:error, :invalid_pattern} = Pattern.compile([:a, :b])
      assert {:error, :invalid_pattern} = Pattern.compile(%{a: 1})
    end
  end

  describe "match?/2" do
    test "exact match" do
      assert Pattern.match?({:task, :pending, "build"}, {:task, :pending, "build"})
    end

    test "wildcard matches any value" do
      assert Pattern.match?({:task, :pending, :_}, {:task, :pending, "build"})
      assert Pattern.match?({:task, :pending, :_}, {:task, :pending, 42})
    end

    test "multiple wildcards" do
      assert Pattern.match?({:task, :_, :_}, {:task, :pending, "build"})
    end

    test "all wildcards" do
      assert Pattern.match?({:_, :_, :_}, {:task, :pending, "build"})
    end

    test "mismatch on literal" do
      refute Pattern.match?({:task, :done, :_}, {:task, :pending, "build"})
    end

    test "mismatch on tuple size" do
      refute Pattern.match?({:task, :pending}, {:task, :pending, "build"})
      refute Pattern.match?({:task, :pending, :_, :_}, {:task, :pending, "build"})
    end

    test "single-element tuples" do
      assert Pattern.match?({:ping}, {:ping})
      refute Pattern.match?({:ping}, {:pong})
    end
  end

  describe "compile/1 works with ETS match_object" do
    setup do
      table = :ets.new(__MODULE__, [:duplicate_bag, :public])
      :ets.insert(table, {:task, :pending, "build"})
      :ets.insert(table, {:task, :done, "deploy"})
      :ets.insert(table, {:result, 42})
      %{table: table}
    end

    test "finds matching tuples via compiled spec", %{table: table} do
      {:ok, spec} = Pattern.compile({:task, :pending, :_})
      results = :ets.match_object(table, spec |> hd() |> elem(0))
      assert results == [{:task, :pending, "build"}]
    end

    test "wildcard matches multiple", %{table: table} do
      {:ok, spec} = Pattern.compile({:task, :_, :_})
      results = :ets.match_object(table, spec |> hd() |> elem(0))
      assert length(results) == 2
    end

    test "no match returns empty", %{table: table} do
      {:ok, spec} = Pattern.compile({:nothing, :here})
      results = :ets.match_object(table, spec |> hd() |> elem(0))
      assert results == []
    end
  end
end

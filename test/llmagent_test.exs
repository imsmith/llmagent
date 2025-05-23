defmodule LLMAgentTest do
  use ExUnit.Case
  doctest LLMAgent

  test "greets the world" do
    assert LLMAgent.hello() == :world
  end
end

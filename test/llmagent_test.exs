defmodule LlmagentTest do
  use ExUnit.Case
  doctest Llmagent

  test "greets the world" do
    assert Llmagent.hello() == :world
  end
end

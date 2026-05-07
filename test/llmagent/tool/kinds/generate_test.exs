defmodule LLMAgent.Tool.Kinds.GenerateTest do
  @moduledoc "Tests for LLMAgent.Tool.Kinds.Generate behaviour."

  use ExUnit.Case, async: true

  test "behaviour exposes generate/2 callback" do
    callbacks = LLMAgent.Tool.Kinds.Generate.behaviour_info(:callbacks)
    assert {:generate, 2} in callbacks
  end

  test "implementations satisfy the contract" do
    defmodule Echo do
      @moduledoc "Test implementation of Generate for contract validation."
      @behaviour LLMAgent.Tool.Kinds.Generate
      @impl true
      def generate("chat", %{messages: msgs}) do
        {:ok, "echo: " <> List.last(msgs)["content"], %{model: "echo"}}
      end
    end

    assert {:ok, "echo: hi", %{model: "echo"}} =
             Echo.generate("chat", %{messages: [%{"role" => "user", "content" => "hi"}]})
  end
end

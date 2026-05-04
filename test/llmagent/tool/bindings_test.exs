defmodule LLMAgent.Tool.BindingsTest do
  @moduledoc false
  use ExUnit.Case, async: false   # mutates persistent_term

  alias LLMAgent.Tool.Bindings

  setup do
    Bindings.init_registry()
    :ok
  end

  describe "init_registry/0" do
    test "seeds :module" do
      assert Bindings.list_bindings() |> Enum.member?(:module)
      assert {:ok, LLMAgent.Tool.Adapter.Module} = Bindings.adapter_for(:module)
    end
  end

  describe "register/2 and unregister/1" do
    test "adds and removes a binding kind" do
      defmodule FakeAdapter do
        @moduledoc false
        @behaviour LLMAgent.Tool.Adapter
      end

      :ok = Bindings.register(:fake, FakeAdapter)
      assert {:ok, FakeAdapter} = Bindings.adapter_for(:fake)

      :ok = Bindings.unregister(:fake)
      assert {:error, :not_found} = Bindings.adapter_for(:fake)
    end

    test "rejects non-module values" do
      assert {:error, :invalid_adapter} = Bindings.register(:bogus, "not a module")
    end
  end

  describe "adapter_for!/1" do
    test "returns the module for a registered binding" do
      assert LLMAgent.Tool.Adapter.Module = Bindings.adapter_for!(:module)
    end

    test "raises for an unknown binding" do
      assert_raise RuntimeError, ~r/binding kind .* not registered/, fn ->
        Bindings.adapter_for!(:nope)
      end
    end
  end
end

defmodule LLMAgent.Tools.BashTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias LLMAgent.Tools.Bash
  alias Comn.Errors.ErrorStruct

  describe "perform/2 with \"exec\"" do
    test "runs a valid command and returns output" do
      {:ok, %{output: output, metadata: %{exit_code: 0}}} =
        Bash.perform("exec", %{"command" => "echo hello"})

      assert output =~ "hello"
    end

    test "returns error for failing command" do
      {:error, %ErrorStruct{} = err} =
        Bash.perform("exec", %{"command" => "exit 42"})

      assert err.reason == "command_failed"
      assert err.field == "command"
      assert err.message =~ "status 42"
    end

    test "returns error for missing command input" do
      result = Bash.perform("exec", %{})
      assert match?({:error, %ErrorStruct{}}, result)
    end

    test "returns error if input is not a string" do
      result = Bash.perform("exec", %{"command" => 123})
      assert match?({:error, _}, result)
    end
  end

  describe "perform/2 with unknown action" do
    test "returns error struct for unsupported action" do
      {:error, %ErrorStruct{} = err} = Bash.perform("explode", %{"command" => "ls"})

      assert err.reason == "unknown_command"
    end
  end

  describe "tool-discovery substrate (via Dispatcher)" do
    alias LLMAgent.{Tools.Bash, Tools.Discovery, Tool.Dispatcher, Tool.Policy}

    setup do
      case Process.whereis(Discovery) do
        nil -> {:ok, _} = Discovery.start_link(consume_announcements: false)
        _ -> Discovery.reset!()
      end

      LLMAgent.Tool.Bindings.init_registry()
      LLMAgent.Tool.Kinds.init_registry()
      :ok = Discovery.register(Bash.ad())
      :ok
    end

    test "ad/0 returns a ToolAd for function.shell.bash with :action kind" do
      ad = Bash.ad()
      assert ad.coordinate == "function.shell.bash"
      assert :action in ad.kinds
      assert ad.fidelity == :authoritative
      assert get_in(ad.constraint, [:blast_radius, "exec"]) == :system
      assert get_in(ad.constraint, [:idempotency, "exec"]) == :non_idempotent
    end

    test "dispatcher.act/5 exec echo hello returns output" do
      policy = %Policy{allow: ["function.shell.bash"], fidelity_min: :authoritative}

      assert {:ok, ack, meta} =
               Dispatcher.act("function.shell.bash", "exec",
                 %{"command" => "echo hello"}, nil, policy: policy)

      # perform("exec", ...) returns {:ok, %{output: string, metadata: map}}
      # act/3 unwraps to {:ok, output_string, metadata_map}
      assert is_binary(ack)
      assert ack =~ "hello"
      assert is_map(meta)
      assert meta[:exit_code] == 0
    end
  end
end

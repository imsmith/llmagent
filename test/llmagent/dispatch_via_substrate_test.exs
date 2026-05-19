defmodule LLMAgent.DispatchViaSubstrateTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias LLMAgent.Tools.Discovery

  defmodule EchoLLMClient do
    @moduledoc false
    @behaviour LLMAgent.LLMClient

    @impl true
    def chat([_system, %{role: "user", content: content} | _], _opts) do
      cond do
        content == "hash this" ->
          {:ok,
           Jason.encode!(%{
             "tool" => "crypto",
             "action" => "sha256",
             "args" => %{"data" => "abc"}
           })}

        true ->
          {:ok, "stopping"}
      end
    end

    @impl true
    def chat([_system | _], _opts), do: {:ok, "stopping"}
  end

  setup do
    Discovery.reset!()
    LLMAgent.Tools.Builtins.register_all()
    :ok
  end

  test "agent loop dispatches a legacy tool call through Tool.Dispatcher" do
    :telemetry_test.attach_event_handlers(self(), [[:llmagent, :tool, :compute]])

    {:ok, _pid} =
      LLMAgent.AgentSupervisor.start_agent(
        name: :substrate_test,
        llm_client: EchoLLMClient,
        allowed_tools: [:crypto]
      )

    on_exit(fn -> LLMAgent.AgentSupervisor.stop_agent(:substrate_test) end)

    LLMAgent.EventBus.subscribe("agent.message")
    LLMAgent.prompt({:global, :substrate_test}, "hash this")

    assert_receive {:event, "agent.message", %{data: %{role: "user", content: "hash this"}}}, 1_000

    assert_receive {:event, "agent.message", %{data: %{role: "function", content: payload}}}, 2_000

    assert {:ok, %{"status" => "ok", "output" => hash}} = Jason.decode(payload)
    assert hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    assert_receive {[:llmagent, :tool, :compute], _, _, %{coordinate: "function.crypto"}}, 1_000
  end
end

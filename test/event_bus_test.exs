defmodule LLMAgent.EventBusTest do
  use ExUnit.Case, async: false

  setup do
    case Registry.start_link(keys: :duplicate, name: LLMAgent.EventBus) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  test "broadcasts messages to subscribers" do
    topic = "test_topic"
    message = "Hello, World!"

    LLMAgent.EventBus.subscribe(topic)
    LLMAgent.EventBus.broadcast(topic, message)

    assert_receive {:event, ^topic, ^message}
  end

  test "does not send messages to unsubscribed topics" do
    topic = "unsubscribed_topic"
    message = "This should not be received"

    LLMAgent.EventBus.subscribe("other_topic")
    LLMAgent.EventBus.broadcast(topic, message)

    refute_receive {:event, ^topic, ^message}
  end
end

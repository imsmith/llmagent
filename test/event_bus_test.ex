
defmodule LLMAgent.EventBusTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, _} = LLMAgent.EventBus.start_link([])
    :ok
  end

  test "broadcasts messages to subscribers" do
    topic = "test_topic"
    message = "Hello, World!"

    pid = self()
    LLMAgent.EventBus.subscribe(topic)

    LLMAgent.EventBus.broadcast(topic, message)

    assert_receive {:event, ^topic, ^message}
  end

  test "does not send messages to unsubscribed topics" do
    topic = "unsubscribed_topic"
    message = "This should not be received"

    pid = self()
    LLMAgent.EventBus.subscribe("other_topic")

    LLMAgent.EventBus.broadcast(topic, message)

    refute_receive {:event, ^topic, ^message}
  end
end

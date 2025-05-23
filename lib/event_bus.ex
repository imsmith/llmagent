defmodule LLMAgent.EventBus do
  def subscribe(topic) do
    Registry.register(__MODULE__, topic, [])
  end

  def broadcast(topic, payload) do
    Registry.dispatch(__MODULE__, topic, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:event, topic, payload})
    end)
  end
end

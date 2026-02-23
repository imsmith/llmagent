defmodule LLMAgent.EventBus do
  @moduledoc """
  Registry-based pub/sub event bus.

  Subscribers receive messages as `{:event, topic, payload}`.
  """

  @doc """
  Subscribe the current process to a topic.

  ## Examples

      iex> {:ok, _} = LLMAgent.EventBus.subscribe("doctest.example")
  """
  def subscribe(topic) do
    Registry.register(__MODULE__, topic, [])
  end

  @doc """
  Broadcast a payload to all subscribers of a topic.

  ## Examples

      iex> LLMAgent.EventBus.subscribe("doctest.broadcast")
      iex> LLMAgent.EventBus.broadcast("doctest.broadcast", :ping)
      iex> receive do
      ...>   {:event, "doctest.broadcast", :ping} -> :ok
      ...> after
      ...>   100 -> :timeout
      ...> end
      :ok
  """
  def broadcast(topic, payload) do
    Registry.dispatch(__MODULE__, topic, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:event, topic, payload})
    end)
  end
end

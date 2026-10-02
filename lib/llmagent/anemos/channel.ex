defmodule LLMAgent.Anemos.Channel do
  @moduledoc """
  `emit ... to channel(path)` as a substrate event.

  The channel path is the topic. The envelope's payload — the value of the
  emitted command, for `[EVENT::name ...]` the event name and its
  arguments — is the event's data, with the emitting rule and the label
  beside it. The event's source is this module, which is how
  `LLMAgent.Anemos.Events` tells a runtime's own emits from everything
  else.
  """

  @behaviour Anemos.Channel

  @impl true
  def publish(channel, %Anemos.Envelope{} = envelope) do
    LLMAgent.Events.emit(
      envelope.type || :anemos,
      channel,
      %{payload: envelope.payload, rule: envelope.source, label: envelope.label},
      __MODULE__
    )
  end
end

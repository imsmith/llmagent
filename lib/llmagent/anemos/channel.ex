defmodule LLMAgent.Anemos.Channel do
  @moduledoc """
  `emit ... to channel(path)` as a substrate event.

  The channel path is the topic. The envelope's payload — the value of the
  emitted command, for `[EVENT::name ...]` the event name and its
  arguments — is the event's data, with the emitting rule and the label
  beside it. The event's source is `{LLMAgent.Anemos.Channel, runtime}`,
  which is how `LLMAgent.Anemos.Events` tells a runtime's own emits from
  everything else, and how anything reading the event log can tell a rule's
  word from a tool's.

  Policy text is untrusted, and this puts its emits on the same bus as
  everything else, under whatever topic the rule named. A consumer that
  acts on a topic has to look at the source.
  """

  @behaviour Anemos.Channel

  @impl true
  def publish(channel, %Anemos.Envelope{} = envelope) do
    runtime =
      case Comn.Contexts.get() do
        %{metadata: %{runtime: runtime}} -> runtime
        _ -> nil
      end

    LLMAgent.Events.emit(
      envelope.type || :anemos,
      channel,
      %{payload: envelope.payload, rule: envelope.source, label: envelope.label},
      {__MODULE__, runtime}
    )
  end
end

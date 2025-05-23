defimpl LLMAgent.Event, for: LLMAgent.Events.EventStruct do
  def to_event(event), do: event
end

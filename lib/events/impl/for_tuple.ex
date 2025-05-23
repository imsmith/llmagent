defimpl LLMAgent.Event, for: Tuple do
  def to_event({type, topic, data}) do
    LLMAgent.Events.EventStruct.new(type, topic, data)
  end
end

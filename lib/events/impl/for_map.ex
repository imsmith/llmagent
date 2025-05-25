defimpl LLMAgent.Event, for: Map do
  def to_event(%{"type" => type, "topic" => topic, "data" => data}) do
    LLMAgent.Events.EventStruct.new(String.to_atom(type), topic, data)
  end

  def to_event(%{type: type, topic: topic, data: data}) do
    LLMAgent.Events.EventStruct.new(type, topic, data)
  end

  def to_event(_invalid) do
    raise ArgumentError, "Map must contain :type, :topic, and :data keys"
  end
end

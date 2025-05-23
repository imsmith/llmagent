defprotocol LLMAgent.Event do
  @doc "Converts various data types into an EventStruct"
  def to_event(term)
end

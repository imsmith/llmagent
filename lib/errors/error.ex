defprotocol LLMAgent.Error do
  @doc "Converts various data types into an ErrorStruct"
  def to_error(term)
end

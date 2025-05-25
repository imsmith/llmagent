defimpl LLMAgent.Error, for: Map do
  def to_error(%{"reason" => reason, "field" => field, "message" => message, "suggestion" => suggestion}) do
    LLMAgent.Errors.ErrorStruct.new(reason, field, message, suggestion)
  end
  def to_error(%{reason: reason, field: field, message: message, suggestion: suggestion}) do
    LLMAgent.Errors.ErrorStruct.new(reason, field, message, suggestion)
  end
  def to_error(_invalid) do
    raise ArgumentError, "Map must contain :reason, :field, :message, and :suggestion keys"
  end

end

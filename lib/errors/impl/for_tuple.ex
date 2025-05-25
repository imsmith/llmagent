defimpl LLMAgent.Error, for: Tuple do
  def to_error({reason, field, message, suggestion}) do
    LLMAgent.Errors.ErrorStruct.new(reason, field, message, suggestion)
  end
end

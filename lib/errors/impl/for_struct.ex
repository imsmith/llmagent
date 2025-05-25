defimpl LLMAgent.Error, for: LLMAgent.Errors.ErrorStruct do
  def to_error(error), do: error
end

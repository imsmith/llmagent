defmodule LLMAgent.Prompts.Default do
  @moduledoc "Simple fallback prompt for non-specialized agents"

  def prompt do
    "You are a helpful assistant."
  end
end

defmodule LLMAgent.Errors.ErrorStruct do
  @moduledoc "Standardized, machine-readable error for AI-facing tools."

  defstruct [
    :reason,
    :field,
    :message,
    :suggestion
  ]

  @type t :: %__MODULE__{
          reason: String.t(),
          field: String.t() | nil,
          message: String.t(),
          suggestion: String.t() | nil
        }

  def new(reason, field, message, suggestion \\ nil) do
    %__MODULE__{
      reason: reason,
      field: field,
      message: message,
      suggestion: suggestion
    }
  end
end

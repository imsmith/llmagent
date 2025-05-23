defmodule LLMAgent.Events.EventStruct do
  @moduledoc "Concrete event struct for immutable system activity logs."

  defstruct [
    :timestamp,
    :source,
    :type,
    :topic,
    :data
  ]

  @type t :: %__MODULE__{
          timestamp: String.t(),
          source: atom() | pid() | binary(),
          type: atom(),
          topic: String.t(),
          data: any()
        }

  def new(type, topic, data, source \\ __MODULE__) do
    %__MODULE__{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      source: source,
      type: type,
      topic: topic,
      data: data
    }
  end
end

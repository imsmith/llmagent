defmodule LLMAgent.Utils.RequireBinary do
  @moduledoc """
  Utility for checking system binaries and emitting events if any are missing.

  This module verifies that required command-line tools (like `wg`, `gpg`, `ssh-keygen`)
  exist in the system's PATH. If a binary is missing, it emits an error event via
  `LLMAgent.EventLog` and `LLMAgent.EventBus`.

  ## Usage

      RequireBinary.check("wg")
      RequireBinary.check_many(["wg", "gpg", "ssh-keygen"])
  """

  alias LLMAgent.Events.EventStruct
  alias LLMAgent.EventLog
  alias LLMAgent.EventBus
  alias LLMAgent.Utils

  @doc "Checks that a single binary exists in the system PATH. Emits an event if missing."
  @spec check(String.t()) :: :ok | {:error, String.t()}
  def check(bin) do
    case System.find_executable(bin) do
      nil ->
        msg = "Required binary '#{bin}' not found in PATH."
        log_event(bin, msg)
        {:error, msg}

      _ ->
        :ok
    end
  end

  @doc "Checks that all binaries in the list are present. Emits one event per missing binary."
  @spec check_many([String.t()]) :: :ok | {:error, [String.t()]}
  def check_many(bins) do
    missing =
      bins
      |> Enum.reject(&(System.find_executable(&1)))
      |> Enum.map(fn bin ->
        msg = "Required binary '#{bin}' not found in PATH."
        log_event(bin, msg)
        msg
      end)

    if missing == [], do: :ok, else: {:error, missing}
  end

  defp log_event(bin, msg) do
    event = %EventStruct{
      timestamp: Utils.Time.call("now_iso8601", []),
      source: __MODULE__,
      type: :error,
      topic: "require_binary:#{bin}",
      data: msg
    }

    EventLog.record(event)
    EventBus.broadcast(event.topic, event)
  end
end

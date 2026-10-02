defmodule LLMAgent.Anemos.Event do
  @moduledoc """
  `EVENT`, the module a rule emits through:

      emit [EVENT::ip.addr.changed :iface "eth0"] to channel(system.config.network)

  The verb is the event's name and the arguments are its key-value pairs;
  the result, `%{"event" => "ip.addr.changed", "iface" => "eth0"}`, is what
  the envelope carries onto the bus. It makes nothing happen on its own —
  it is the message, and `emit` is what sends it.
  """

  @behaviour Anemos.Runtime.Module

  @impl true
  def handle_verb(event, args, _context) do
    with {:ok, pairs} <- pairs(args), do: {:ok, Map.put(pairs, "event", event)}
  end

  defp pairs(args) do
    if rem(length(args), 2) == 0 and Enum.all?(Enum.take_every(args, 2), &is_binary/1) do
      {:ok, args |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {k, v} end)}
    else
      {:error, :args_must_be_key_value_pairs}
    end
  end
end

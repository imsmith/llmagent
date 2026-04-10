defmodule LLMAgent.MCP.Transport do
  @moduledoc """
  Behaviour for MCP transport implementations.

  A transport handles the low-level communication with an MCP server
  over a specific protocol (HTTP, stdio, etc.). The Connection GenServer
  holds the transport module and its opaque state.
  """

  @type request :: %{method: String.t(), params: map(), id: integer()}
  @type response :: {:ok, map()} | {:error, :timeout | :closed | :invalid_response | atom()}
  @type transport_state :: map()

  @doc "Start the transport with the given opts and return its initial opaque state. Returns `{:ok, state}` or `{:error, :invalid_opts | :connection_failed | atom()}`."
  @callback start(opts :: keyword()) :: {:ok, transport_state()} | {:error, :invalid_opts | :connection_failed | atom()}

  @doc "Send a JSON-RPC request and return `{response, new_state}`. Response is `{:ok, map()}` or `{:error, :timeout | :closed | :invalid_response | atom()}`. State is always returned so the caller can retry or close."
  @callback send_request(state :: transport_state(), request()) :: {response(), new_state :: transport_state()}

  @doc "Close the transport and release resources. Always returns `:ok`; teardown errors are logged but not surfaced."
  @callback close(state :: transport_state()) :: :ok
end

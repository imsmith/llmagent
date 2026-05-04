defmodule LLMAgent.Tool.Kinds.Stream do
  @moduledoc """
  The `:stream` kind. Subscribe/unsubscribe to event streams.

  Use `:stream` when the tool emits a sequence of events over time rather than
  returning a single value. Subscribers receive messages from the tool's process
  and unsubscribe via the reference returned by `subscribe/3`. The agent is
  responsible for calling `unsubscribe/1` when the stream is no longer needed.

  See `docs/superpowers/specs/2026-05-03-tool-discovery-design.md` §3.3.

  ## Minimal implementation

  Implement `@behaviour LLMAgent.Tool.Kinds.Stream` and define `subscribe/3`
  and `unsubscribe/1`:

  ```elixir
  @behaviour LLMAgent.Tool.Kinds.Stream

  @impl true
  def subscribe("sensor_readings", _args, pid) do
    ref = make_ref()
    # register pid+ref, start sending events ...
    {:ok, ref}
  end

  @impl true
  def unsubscribe(ref) do
    # deregister ref ...
    :ok
  end
  ```
  """

  @doc "Subscribe to a stream. Returns `{:ok, sub_ref}` with a subscription reference or `{:error, reason}` on failure."
  @callback subscribe(action :: String.t(), args :: map(), subscriber :: pid()) ::
              {:ok, sub_ref :: reference()} | {:error, atom()}

  @doc "Unsubscribe from a stream using the subscription reference. Returns `:ok`."
  @callback unsubscribe(sub_ref :: reference()) :: :ok
end

defmodule LLMAgent.Memory do
  @moduledoc """
  Behaviour for agent memory backends.

  Each agent gets an isolated namespace keyed by `agent_id`.
  Designed for future tuple-space implementation.

  ## Implementing a Backend

      defmodule MyMemory do
        @behaviour LLMAgent.Memory

        @impl true
        def init(_agent_id, _opts), do: :ok

        @impl true
        def store(_agent_id, _key, _value), do: :ok

        @impl true
        def fetch(_agent_id, _key), do: {:error, :not_found}

        @impl true
        def delete(_agent_id, _key), do: :ok

        @impl true
        def list(_agent_id), do: {:ok, []}

        @impl true
        def teardown(_agent_id), do: :ok
      end

  ## Well-Known Keys

  - `:history` — conversation message list
  - `:metadata` — agent role, model, etc.
  """

  @type agent_id :: atom()

  @callback init(agent_id, opts :: keyword()) :: :ok | {:error, term()}
  @callback store(agent_id, key :: term(), value :: term()) :: :ok | {:error, term()}
  @callback fetch(agent_id, key :: term()) :: {:ok, term()} | {:error, :not_found}
  @callback delete(agent_id, key :: term()) :: :ok | {:error, term()}
  @callback list(agent_id) :: {:ok, [{term(), term()}]} | {:error, term()}
  @callback teardown(agent_id) :: :ok
end

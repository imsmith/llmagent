defmodule LLMAgent do
  use GenServer

  @doc """
  Starts a new LLMAgent process registered globally under the given name.
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: {:global, name})
  end

  @impl true
  def init(opts) do
    {:ok, %{model: Keyword.get(opts, :model), history: []}}
  end

  @doc """
  Sends a prompt to the agent and returns the response.
  """
  def prompt(pid, model, prompt) do
    GenServer.call(pid, {:prompt, model, prompt})
  end

  @impl true
  def handle_call({:prompt, model, prompt}, _from, state) do
    # Mocked LLM call
    response = "[#{model}] Echo: #{prompt}"

    new_state = update_in(state[:history], &[{prompt, response} | &1])
    {:reply, response, new_state}
  end
end

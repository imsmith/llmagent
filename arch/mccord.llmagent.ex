defmodule LLMAgent do
    use GenServer

    def prompt(pid, model, prompt) do
        GenServer.call(pid, {:prompt, prompt})
    end

    def init(_) do
        {:ok, %{history: [%{role: "system", content: @system_prompt}]}}
    end

    def handle_call({:prompt, prompt} , from, state) do
        {:reply, :ok, continue_chat(state, prompt)}
    end

    defp continue_chat(state, prompt) do
        new_history = state.history ++ [%{role: "user", content: prompt}]
        Task.Supervisor.async(LLMAgent.TaskSup, fn ->
            Req.post("#{@api_host}/chat/completions", json: %{messages: new_history})
        end)
        %{state | history: new_history}
    end

    defp handle_info({_ref, {:ok, api_response}}, state) do
        new_history = state.history ++ [%{role: "assistant", content: api_response}]
        user_response = invoke_tool(api_response)
        {:noreply, continue_chat(%{state | history: new_history}, user_response)}
    end

end

defmodule LLMAgent do
  use GenServer
  require Logger

  alias LLMAgent.RolePrompt
  alias LLMAgent.Tools
  alias Comn.Errors.ErrorStruct
  alias Comn.Events.EventStruct

  @default_model "gpt-4"
  @default_api_host "http://localhost:4000"

  ## Public API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  def prompt(agent \\ __MODULE__, content) do
    GenServer.call(agent, {:prompt, content})
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    role = Keyword.get(opts, :role, :default)

    state = %{
      role: role,
      model: Keyword.get(opts, :model, @default_model),
      api_host: Keyword.get(opts, :api_host, @default_api_host),
      history: [%{role: "system", content: RolePrompt.get(role)}]
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:prompt, user_input}, _from, state) do
    updated = do_prompt(user_input, state)
    {:reply, :ok, updated}
  end

  @impl true
  def handle_info({ref, {:ok, %{"choices" => [%{"message" => %{"content" => content}}]}}}, state) do
    Process.demonitor(ref, [:flush])

    emit_event(:llm_response, "agent.llm_response", %{
      content_length: String.length(content),
      is_tool_call: tool_call?(content)
    })

    case parse_tool_call(content) do
      {:tool_call, tool, action, args} ->
        emit_event(:tool_dispatch, "agent.tool_dispatch", %{tool: tool, action: action})

        result = timed_dispatch(tool, action, args)
        followup = format_tool_result(result)

        updated =
          state
          |> append_message("assistant", content)
          |> append_message("function", followup)

        send(self(), {:prompt, followup})
        {:noreply, updated}

      :not_a_tool_call ->
        updated = append_message(state, "assistant", content)
        {:noreply, updated}
    end
  end

  def handle_info({ref, {:error, reason}}, state) do
    Process.demonitor(ref, [:flush])

    emit_event(:error, "agent.error", %{
      reason: inspect(reason),
      source: :llm_request
    })

    Logger.error("LLM request failed: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info({:prompt, content}, state) do
    updated = do_prompt(content, state)
    {:noreply, updated}
  end

  ## Prompt Logic

  defp do_prompt(user_input, state) do
    emit_event(:prompt, "agent.prompt", %{content: user_input, role: state.role})

    updated = append_message(state, "user", user_input)

    Task.Supervisor.async(LLMAgent.TaskSup, fn ->
      call_llm(updated.api_host, updated.model, updated.history)
    end)

    updated
  end

  ## Tool Dispatch

  defp timed_dispatch(tool, action, args) do
    start = System.monotonic_time(:millisecond)

    result = dispatch_tool(tool, action, args)

    duration_ms = System.monotonic_time(:millisecond) - start

    {result_status, _} = case result do
      {:ok, _} -> {:ok, nil}
      {:error, _} -> {:error, nil}
    end

    emit_event(:invocation, "tool.#{tool}", %{
      action: action,
      args: sanitize_args(args),
      result: result_status,
      duration_ms: duration_ms
    })

    result
  end

  defp dispatch_tool(tool, action, args) do
    try do
      tool_module = apply(Tools, tool, [])

      if function_exported?(tool_module, :perform, 2) do
        tool_module.perform(action, args)
      else
        {:error, ErrorStruct.new("invalid_tool", "tool", "Tool does not implement perform/2")}
      end
    rescue
      _ ->
        {:error, ErrorStruct.new("invalid_tool", "tool", "Tool #{tool} not found")}
    end
  end

  ## Helpers

  defp append_message(state, role, content) do
    update_in(state.history, &(&1 ++ [%{role: role, content: content}]))
  end

  defp call_llm(api_host, model, messages) do
    Req.post("#{api_host}/chat/completions", json: %{
      model: model,
      messages: messages
    })
  end

  defp parse_tool_call(content) do
    case Jason.decode(content) do
      {:ok, %{"tool" => tool, "action" => action, "args" => args}} ->
        {:tool_call, String.to_atom(tool), action, args}

      _ ->
        :not_a_tool_call
    end
  end

  defp tool_call?(content) do
    case Jason.decode(content) do
      {:ok, %{"tool" => _, "action" => _}} -> true
      _ -> false
    end
  end

  defp format_tool_result({:ok, result}), do: inspect(result)

  defp format_tool_result({:error, error}) do
    error_struct = Comn.Error.to_error(error)
    "[Tool Error] #{to_string(error_struct)}"
  end

  defp emit_event(type, topic, data) do
    event = EventStruct.new(type, topic, data, __MODULE__)
    LLMAgent.EventLog.record(event)
    LLMAgent.EventBus.broadcast(topic, event)
  rescue
    _ -> :ok
  end

  defp sanitize_args(args) when is_map(args) do
    Map.new(args, fn
      {k, v} when is_binary(v) and byte_size(v) > 200 ->
        {k, String.slice(v, 0, 200) <> "...(truncated)"}
      {k, v} -> {k, v}
    end)
  end

  defp sanitize_args(args), do: args

  defp via(name) when is_atom(name), do: {:global, name}
end

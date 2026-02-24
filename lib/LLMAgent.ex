defmodule LLMAgent do
  use GenServer
  require Logger

  alias LLMAgent.RolePrompt
  alias LLMAgent.Tools
  alias LLMAgent.Events
  alias Comn.Errors.ErrorStruct
  alias Comn.Contexts

  @default_model "gpt-4"
  @default_api_host "http://localhost:11434/v1"

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
    name = Keyword.get(opts, :name, __MODULE__)
    role = Keyword.get(opts, :role, :default)
    memory = Keyword.get(opts, :memory, LLMAgent.Memory.ETS)
    llm_client = Keyword.get(opts, :llm_client, LLMAgent.LLMClient.OpenAI)

    memory.init(name)

    {history, restored?} = restore_history(name, role, memory)

    state = %{
      name: name,
      role: role,
      model: Keyword.get(opts, :model, @default_model),
      api_host: Keyword.get(opts, :api_host, @default_api_host),
      llm_client: llm_client,
      memory: memory,
      history: history
    }

    unless restored? do
      Events.emit(:message, "agent.message", %{
        agent_id: name,
        role: "system",
        content: hd(history).content
      }, __MODULE__)
    end

    memory.store(name, :history, state.history)

    {:ok, state}
  end

  defp restore_history(name, role, memory) do
    case LLMAgent.DurableLog.messages_for(name) do
      messages when is_list(messages) and messages != [] ->
        {messages, true}

      _ ->
        case memory.fetch(name, :history) do
          {:ok, saved} when saved != [] -> {saved, true}
          _ -> {[%{role: "system", content: RolePrompt.get(role)}], false}
        end
    end
  end

  @impl true
  def handle_call({:prompt, user_input}, _from, state) do
    updated = do_prompt(user_input, state)
    {:reply, :ok, updated}
  end

  @impl true
  def handle_info({ref, {:ok, content}}, state) when is_binary(content) do
    Process.demonitor(ref, [:flush])

    Events.emit(:llm_response, "agent.llm_response", %{
      content_length: String.length(content),
      is_tool_call: tool_call?(content)
    }, __MODULE__)

    case parse_tool_call(content) do
      {:tool_call, tool, action, args} ->
        Events.emit(:tool_dispatch, "agent.tool_dispatch", %{tool: tool, action: action}, __MODULE__)

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

    Events.emit(:error, "agent.error", %{
      reason: inspect(reason),
      source: :llm_request
    }, __MODULE__)

    Logger.error("LLM request failed: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info({:prompt, content}, state) do
    updated = do_prompt(content, state)
    {:noreply, updated}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    state.memory.store(state.name, :history, state.history)
    :ok
  end

  ## Prompt Logic

  defp do_prompt(user_input, state) do
    request_id = "req_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    trace_id = state[:trace_id] || "trace_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    Contexts.new(%{
      request_id: request_id,
      trace_id: trace_id,
      actor: "agent"
    })
    Contexts.put(:role, state.role)
    Contexts.put(:model, state.model)

    Events.emit(:prompt, "agent.prompt", %{content: user_input, role: state.role}, __MODULE__)

    updated = append_message(state, "user", user_input)

    client_opts = %{api_host: updated.api_host, model: updated.model, timeout: 120_000}

    Task.Supervisor.async(LLMAgent.TaskSup, fn ->
      updated.llm_client.chat(updated.history, client_opts)
    end)

    updated
  end

  ## Tool Dispatch

  defp timed_dispatch(tool, action, args) do
    Contexts.put(:tool, tool)
    Contexts.put(:action, action)

    start = System.monotonic_time(:millisecond)

    result = dispatch_tool(tool, action, args)

    duration_ms = System.monotonic_time(:millisecond) - start

    {result_status, _} = case result do
      {:ok, _} -> {:ok, nil}
      {:error, _} -> {:error, nil}
    end

    Events.emit(:invocation, "tool.#{tool}", %{
      action: action,
      args: sanitize_args(args),
      result: result_status,
      duration_ms: duration_ms
    }, __MODULE__)

    result
  end

  defp dispatch_tool(tool, action, args) do
    case Tools.get(tool) do
      {:ok, tool_module} ->
        tool_module.perform(action, args)

      {:error, :not_found} ->
        {:error, ErrorStruct.new("invalid_tool", "tool", "Tool #{tool} not found")}
    end
  end

  ## Helpers

  defp append_message(state, role, content) do
    updated = update_in(state.history, &(&1 ++ [%{role: role, content: content}]))
    state.memory.store(state.name, :history, updated.history)

    Events.emit(:message, "agent.message", %{
      agent_id: state.name,
      role: role,
      content: content
    }, __MODULE__)

    updated
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

  defp format_tool_result({:ok, %{output: output, metadata: metadata}}) do
    Jason.encode!(%{status: "ok", output: output, metadata: metadata})
  end

  defp format_tool_result({:error, %ErrorStruct{} = err}) do
    Jason.encode!(%{
      status: "error",
      error: %{
        reason: err.reason,
        field: err.field,
        message: err.message,
        suggestion: err.suggestion
      }
    })
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

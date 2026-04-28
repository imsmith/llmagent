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
    parent = Keyword.get(opts, :parent, nil)
    allowed_tools = Keyword.get(opts, :allowed_tools, :all)

    parent_ref =
      case parent do
        nil -> nil
        parent_name ->
          case GenServer.whereis({:global, parent_name}) do
            nil -> nil
            pid -> Process.monitor(pid)
          end
      end

    memory.init(name)

    {history, restored?} = restore_history(name, role, memory)

    state = %{
      name: name,
      role: role,
      model: Keyword.get(opts, :model, @default_model),
      api_host: Keyword.get(opts, :api_host, @default_api_host),
      llm_client: llm_client,
      memory: memory,
      history: history,
      parent: parent,
      allowed_tools: allowed_tools,
      parent_ref: parent_ref
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

        result = timed_dispatch(tool, action, args, state.allowed_tools)
        followup = format_tool_result(result)

        updated =
          state
          |> append_message("assistant", content)
          |> append_message("function", followup)

        send(self(), {:prompt, followup})
        {:noreply, updated}

      :not_a_tool_call ->
        updated = append_message(state, "assistant", content)

        case updated.parent do
          nil ->
            {:noreply, updated}

          _parent ->
            LLMAgent.TupleSpace.out({:agent_result, updated.name, content})
            send(self(), :child_complete_stop)
            {:noreply, updated}
        end
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

  def handle_info(:child_complete_stop, state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{parent_ref: ref} = state) do
    Events.emit(:orphaned, "agent.orphaned", %{
      agent_id: state.name,
      parent: state.parent
    }, __MODULE__)

    {:noreply, %{state | parent_ref: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    state.memory.store(state.name, :history, state.history)

    if state.parent != nil and reason not in [:normal, :shutdown] do
      try do
        LLMAgent.TupleSpace.out({:agent_error, state.name, inspect(reason)})
      catch
        _, _ -> :ok
      end
    end

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
    Contexts.put(:agent_name, state.name)
    Contexts.put(:agent_parent, state.parent)

    Events.emit(:prompt, "agent.prompt", %{content: user_input, role: state.role}, __MODULE__)

    updated = append_message(state, "user", user_input)

    client_opts = %{api_host: updated.api_host, model: updated.model, timeout: 120_000}

    Task.Supervisor.async(LLMAgent.TaskSup, fn ->
      updated.llm_client.chat(updated.history, client_opts)
    end)

    updated
  end

  ## Tool Dispatch

  defp timed_dispatch(tool, action, args, allowed) do
    Contexts.put(:tool, tool)
    Contexts.put(:action, action)

    start = System.monotonic_time(:millisecond)

    result =
      if tool_allowed?(tool, allowed) do
        dispatch_tool(tool, action, args)
      else
        {:error,
         ErrorStruct.new("tool_not_permitted", "tool",
           "tool :#{tool} not permitted", "Use one of the allowed tools")}
      end

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

  defp tool_allowed?(_tool, :all), do: true
  defp tool_allowed?(tool, allowed) when is_list(allowed), do: tool in allowed

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

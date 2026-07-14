defmodule LLMAgent do
  @moduledoc """
  Top-level agent GenServer. Manages conversation history, dispatches tool
  calls through `Tool.Dispatcher`, and drives the prompt/response loop.
  """

  use GenServer
  require Logger

  alias LLMAgent.RolePrompt
  alias LLMAgent.Events
  alias LLMAgent.Tool.{Dispatcher, Policy}
  alias LLMAgent.Tools
  alias Comn.Errors.ErrorStruct
  alias Comn.Contexts

  @default_model "gpt-4"
  @default_api_host "http://localhost:11434/v1"

  # Map legacy tool atom names to their substrate coordinates. Stays here
  # until §7.6 step 9 (LLM-facing catalog regeneration), then is removed.
  @legacy_coordinate %{
    bash:        {"function.shell.bash",              :action},
    web:         {"function.http",                    nil},
    dbus:        {"function.dbus",                    nil},
    systemd:     {"function.systemd",                 nil},
    inotify:     {"resource.fs.events",               :stream},
    udev:        {"resource.hardware.events",          nil},
    file:        {"resource.fs.file",                 nil},
    net:         {"resource.network",                 :query},
    proc:        {"resource.proc",                    :query},
    crypto:      {"function.crypto",                  :compute},
    tuple_space: {"function.coordination.tuplespace", nil},
    agent:       {"function.agent",                   :spawn}
  }

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
        Events.emit(:tool_dispatch, "agent.tool_dispatch", %{agent_id: state.name, tool: tool, action: action}, __MODULE__)

        result = timed_dispatch(tool, action, args, state.allowed_tools, state.name)
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

  defp timed_dispatch(tool, action, args, allowed, agent_id) do
    Contexts.put(:tool, tool)
    Contexts.put(:action, action)

    start = System.monotonic_time(:millisecond)

    result =
      if tool_allowed?(tool, allowed) do
        dispatch_tool(tool, action, args, allowed)
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
      agent_id: agent_id,
      action: action,
      args: sanitize_args(args),
      result: result_status,
      duration_ms: duration_ms
    }, __MODULE__)

    result
  end

  defp tool_allowed?(_tool, :all), do: true
  defp tool_allowed?(tool, allowed) when is_list(allowed), do: tool in allowed

  defp dispatch_tool(tool, action, args, allowed_tools) do
    case Map.fetch(@legacy_coordinate, tool) do
      {:ok, {coordinate, fixed_kind}} ->
        policy = Policy.from_legacy_or_struct(allowed_tools_to_policy(allowed_tools))
        kind = fixed_kind || infer_kind(coordinate, action)

        case invoke_via_dispatcher(kind, coordinate, action, args, policy) do
          {:error, %ErrorStruct{reason: "dispatch_failed"}} ->
            # Discovery returned :not_found — fall back to legacy Tools registry.
            # Stays until §7.6 step 9 removes the legacy path.
            legacy_dispatch(tool, action, args)

          other ->
            other
        end

      :error ->
        {:error, ErrorStruct.new("invalid_tool", "tool", "Tool #{tool} not found")}
    end
  end

  defp legacy_dispatch(tool, action, args) do
    case Tools.get(tool) do
      {:ok, tool_module} ->
        tool_module.perform(action, args)

      {:error, :not_found} ->
        {:error, ErrorStruct.new("invalid_tool", "tool", "Tool #{tool} not found")}
    end
  end

  defp allowed_tools_to_policy(:all) do
    %Policy{
      allow: ["function.*", "resource.*", "legacy.*"],
      fidelity_min: :authoritative
    }
  end

  defp allowed_tools_to_policy(list) when is_list(list) do
    coordinates =
      Enum.map(list, fn name ->
        case Map.fetch(@legacy_coordinate, name) do
          {:ok, {coord, _}} -> coord
          :error -> "legacy.#{name}"
        end
      end)

    %Policy{
      allow: Enum.map(coordinates, &%{coordinate: &1, kinds: :any, actions: :any}),
      fidelity_min: :authoritative
    }
  end

  defp infer_kind(coordinate, action) do
    alias LLMAgent.{ToolQuery, Tools.Discovery}

    case Discovery.find_one(ToolQuery.new(%{coordinate: coordinate})) do
      {:ok, ad} ->
        cond do
          :query in ad.kinds and get_in(ad.constraint, [:idempotency, action]) == :idempotent ->
            :query

          :action in ad.kinds ->
            :action

          true ->
            hd(ad.kinds)
        end

      _ ->
        :action
    end
  end

  defp invoke_via_dispatcher(:query, coord, action, args, policy) do
    case Dispatcher.query(coord, action, args, policy: policy) do
      {:ok, out, meta} -> {:ok, %{output: out, metadata: meta}}
      err -> normalize_dispatcher_error(err)
    end
  end

  defp invoke_via_dispatcher(:action, coord, action, args, policy) do
    case Dispatcher.act(coord, action, args, nil, policy: policy) do
      {:ok, ack, meta} -> {:ok, %{output: ack, metadata: meta}}
      err -> normalize_dispatcher_error(err)
    end
  end

  defp invoke_via_dispatcher(:compute, coord, action, args, policy) do
    case Dispatcher.compute(coord, action, args, policy: policy) do
      {:ok, value} -> {:ok, %{output: value, metadata: %{}}}
      {:ok, value, meta} -> {:ok, %{output: value, metadata: meta}}
      err -> normalize_dispatcher_error(err)
    end
  end

  defp invoke_via_dispatcher(:stream, _coord, _action, _args, _policy) do
    {:error,
     ErrorStruct.new(
       "stream_via_loop",
       "kind",
       "stream tools cannot be invoked through the prompt/response loop; use Dispatcher.subscribe/5 directly"
     )}
  end

  defp invoke_via_dispatcher(:spawn, coord, action, args, policy) do
    case Dispatcher.spawn_child(coord, {action, args}, policy: policy) do
      {:ok, child_ref} -> {:ok, %{output: child_ref, metadata: %{}}}
      err -> normalize_dispatcher_error(err)
    end
  end

  defp normalize_dispatcher_error({:error, :forbidden, reason}),
    do:
      {:error,
       ErrorStruct.new(
         "forbidden",
         "policy",
         "Policy denied: #{reason}",
         "Update allowed_tools or the agent's policy"
       )}

  defp normalize_dispatcher_error({:error, %ErrorStruct{} = e}), do: {:error, e}

  defp normalize_dispatcher_error({:error, reason}),
    do: {:error, ErrorStruct.new("dispatch_failed", "tool", inspect(reason))}

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
    case Jason.decode(strip_code_fences(content)) do
      {:ok, %{"tool" => tool, "action" => action, "args" => args}} ->
        {:tool_call, String.to_atom(tool), action, args}

      _ ->
        :not_a_tool_call
    end
  end

  defp tool_call?(content) do
    case Jason.decode(strip_code_fences(content)) do
      {:ok, %{"tool" => _, "action" => _}} -> true
      _ -> false
    end
  end

  # Small models often wrap tool-call JSON in a markdown code fence
  # (```json … ``` or ``` … ```). Strip a single leading/trailing fence
  # so the payload decodes; non-fenced content passes through untouched.
  defp strip_code_fences(content) when is_binary(content) do
    trimmed = String.trim(content)

    case Regex.run(~r/\A```(?:[a-zA-Z0-9_-]+)?\n(.*)\n```\z/s, trimmed) do
      [_, inner] -> String.trim(inner)
      _ -> trimmed
    end
  end

  defp strip_code_fences(content), do: content

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

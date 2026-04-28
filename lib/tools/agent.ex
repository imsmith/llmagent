defmodule LLMAgent.Tools.Agent do
  @moduledoc """
  Lifecycle-only tool for spawning, killing, listing, and inspecting child agents.

  Communication between parent and child happens through the tuple space — see
  `LLMAgent.Tools.TupleSpace`. This tool intentionally does not carry payloads.

  Caller identity (`agent_name`, `agent_parent`) is read from `Comn.Contexts`,
  populated by `LLMAgent` on each prompt.
  """

  @behaviour LLMAgent.Tool
  alias LLMAgent.AgentSupervisor
  alias Comn.Errors.ErrorStruct
  alias Comn.Contexts

  @default_sync_timeout 120_000

  @impl true
  def describe do
    """
    Spawn and manage child agents. One level deep — children cannot spawn further.

    Actions:
      - spawn {name, prompt, tools, mode, model?, timeout?}: start a child agent.
        - mode: "sync" blocks for the child's final response.
        - mode: "async" returns immediately; child writes {:agent_result, name, content}
          to the :default tuple space on completion.
        - tools: array of tool name strings (whitelist).
      - kill {name}: stop a running child.
      - list {}: list running children with state.
      - status {name}: { running: bool, name: string }.
    """
  end

  @impl true
  def perform("spawn", args), do: do_spawn(args)

  def perform("kill", %{"name" => name}) when is_binary(name) do
    case AgentSupervisor.stop_agent(String.to_atom(name)) do
      :ok -> {:ok, %{output: "ok", metadata: %{action: "kill"}}}
      {:error, :not_found} ->
        {:error, ErrorStruct.new("not_found", "name", "agent #{name} not found")}
    end
  end

  def perform("list", _args) do
    list =
      AgentSupervisor.list_agents_with_state()
      |> Enum.map(fn s ->
        %{
          "name" => Atom.to_string(s.name),
          "role" => Atom.to_string(s.role),
          "model" => s.model,
          "history_length" => s.history_length
        }
      end)

    {:ok, %{output: list, metadata: %{action: "list"}}}
  end

  def perform("status", %{"name" => name}) when is_binary(name) do
    running = GenServer.whereis({:global, String.to_atom(name)}) != nil
    {:ok, %{output: %{"running" => running, "name" => name}, metadata: %{action: "status"}}}
  end

  def perform(_, _),
    do: {:error, ErrorStruct.new("unknown_command", nil, "Unrecognized Agent action")}

  ## Spawn

  defp do_spawn(%{"name" => name, "prompt" => prompt, "tools" => tools, "mode" => mode} = args)
       when is_binary(name) and is_binary(prompt) and is_list(tools) and is_binary(mode) do
    caller_parent = Contexts.fetch(:agent_parent)
    caller_name = Contexts.fetch(:agent_name)

    cond do
      caller_parent != nil ->
        {:error,
         ErrorStruct.new("spawn_depth_exceeded", nil,
           "child agents cannot spawn further agents")}

      true ->
        spawn_with_mode(mode, name, prompt, tools, caller_name, args)
    end
  end

  defp do_spawn(_),
    do: {:error, ErrorStruct.new("invalid_args", nil, "spawn requires name, prompt, tools, mode")}

  defp spawn_with_mode("async", name, prompt, tools, parent, args) do
    case start_child(name, prompt, tools, parent, args) do
      {:ok, _pid} ->
        LLMAgent.prompt({:global, String.to_atom(name)}, prompt)
        {:ok, %{output: "agent #{name} started", metadata: %{action: "spawn", mode: "async"}}}

      {:error, reason} ->
        {:error,
         ErrorStruct.new("spawn_failed", "name", "could not start #{name}: #{inspect(reason)}")}
    end
  end

  defp spawn_with_mode("sync", _name, _prompt, _tools, _parent, _args) do
    {:error, ErrorStruct.new("not_implemented", "mode", "sync mode not yet implemented")}
  end

  defp spawn_with_mode(other, _name, _prompt, _tools, _parent, _args) do
    {:error, ErrorStruct.new("invalid_mode", "mode", "unknown spawn mode: #{other}")}
  end

  defp start_child(name, _prompt, tools, parent, args) do
    opts = [
      name: String.to_atom(name),
      parent: parent,
      allowed_tools: Enum.map(tools, &String.to_atom/1)
    ]

    opts =
      case Map.get(args, "model") do
        nil -> opts
        model when is_binary(model) -> Keyword.put(opts, :model, model)
      end

    AgentSupervisor.start_agent(opts)
  end
end

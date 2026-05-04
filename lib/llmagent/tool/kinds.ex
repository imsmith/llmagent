defmodule LLMAgent.Tool.Kinds do
  @moduledoc """
  Registry mapping kind atoms to their behaviour modules.

  Backed by `:persistent_term` for fast reads. Mutations rewrite the whole map.
  See spec §3.8.
  """

  @key :llmagent_tool_kinds

  @canonical %{
    query:      LLMAgent.Tool.Kinds.Query,
    action:     LLMAgent.Tool.Kinds.Action,
    stream:     LLMAgent.Tool.Kinds.Stream,
    compute:    LLMAgent.Tool.Kinds.Compute,
    coordinate: LLMAgent.Tool.Kinds.Coordinate,
    spawn:      LLMAgent.Tool.Kinds.SpawnKind
  }

  @doc "Seed the registry with the canonical six kinds."
  @spec init_registry() :: :ok
  def init_registry do
    :persistent_term.put(@key, @canonical)
    :ok
  end

  @doc "Return the list of registered kind atoms."
  @spec list_kinds() :: [atom()]
  def list_kinds, do: get_all() |> Map.keys()

  @doc "Look up a kind's behaviour module."
  @spec behaviour_for(atom()) :: {:ok, module()} | {:error, :not_found}
  def behaviour_for(kind) when is_atom(kind) do
    case Map.fetch(get_all(), kind) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, :not_found}
    end
  end

  @doc "Register a new kind. The behaviour module must be loaded and define behaviour_info/1."
  @spec register_kind(atom(), module()) :: :ok | {:error, :invalid_behaviour}
  def register_kind(kind, behaviour_module)
      when is_atom(kind) and is_atom(behaviour_module) do
    Code.ensure_loaded(behaviour_module)

    cond do
      function_exported?(behaviour_module, :behaviour_info, 1) ->
        :persistent_term.put(@key, Map.put(get_all(), kind, behaviour_module))
        :ok

      true ->
        {:error, :invalid_behaviour}
    end
  end

  def register_kind(_kind, _other), do: {:error, :invalid_behaviour}

  @doc "Remove a kind from the registry."
  @spec unregister_kind(atom()) :: :ok
  def unregister_kind(kind) when is_atom(kind) do
    :persistent_term.put(@key, Map.delete(get_all(), kind))
    :ok
  end

  defp get_all, do: :persistent_term.get(@key, %{})
end

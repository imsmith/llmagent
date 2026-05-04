defmodule LLMAgent.Tool.Bindings do
  @moduledoc """
  Registry mapping binding-kind atoms to their adapter modules.

  Same `:persistent_term` shape as `LLMAgent.Tool.Kinds`. Seeded at application
  boot with the canonical `:module` adapter. Additional adapters (`:process`,
  `:remote`, `:http`, `:mcp`) are added in follow-on plans.

  The binding kind is the first element of a `ToolAd.binding` tuple. When the
  dispatcher resolves an ad, it calls `adapter_for/1` to get the adapter module
  and then delegates the kind call to it with the binding payload as first arg.

  See `docs/superpowers/specs/2026-05-03-tool-discovery-design.md` §4.4.

  ## Registering a new binding adapter

  Write a module implementing `@behaviour LLMAgent.Tool.Adapter`, then register
  it at boot:

  ```elixir
  :ok = LLMAgent.Tool.Bindings.register(:http, MyApp.Tool.Adapter.HTTP)
  {:ok, MyApp.Tool.Adapter.HTTP} = LLMAgent.Tool.Bindings.adapter_for(:http)
  ```
  """

  @key :llmagent_tool_bindings

  @canonical %{module: LLMAgent.Tool.Adapter.Module}

  @doc "Seed the registry with canonical bindings."
  @spec init_registry() :: :ok
  def init_registry do
    :persistent_term.put(@key, @canonical)
    :ok
  end

  @doc """
  Return the list of registered binding-kind atoms.

  ## Examples

      iex> :module in LLMAgent.Tool.Bindings.list_bindings()
      true
  """
  @spec list_bindings() :: [atom()]
  def list_bindings, do: get_all() |> Map.keys()

  @doc """
  Look up an adapter module by binding kind.

  ## Examples

      iex> {:ok, mod} = LLMAgent.Tool.Bindings.adapter_for(:module)
      iex> mod
      LLMAgent.Tool.Adapter.Module

      iex> LLMAgent.Tool.Bindings.adapter_for(:nope)
      {:error, :not_found}
  """
  @spec adapter_for(atom()) :: {:ok, module()} | {:error, :not_found}
  def adapter_for(kind) when is_atom(kind) do
    case Map.fetch(get_all(), kind) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Like `adapter_for/1`, but raises if the binding kind is not registered.

  ## Examples

      iex> LLMAgent.Tool.Bindings.adapter_for!(:module)
      LLMAgent.Tool.Adapter.Module
  """
  @spec adapter_for!(atom()) :: module()
  def adapter_for!(kind) do
    case adapter_for(kind) do
      {:ok, mod} -> mod
      {:error, :not_found} -> raise "binding kind #{inspect(kind)} not registered"
    end
  end

  @doc "Register an adapter module for a binding kind."
  @spec register(atom(), module()) :: :ok | {:error, :invalid_adapter}
  def register(kind, adapter_module) when is_atom(kind) and is_atom(adapter_module) do
    Code.ensure_loaded(adapter_module)

    if function_exported?(adapter_module, :module_info, 0) do
      :persistent_term.put(@key, Map.put(get_all(), kind, adapter_module))
      :ok
    else
      {:error, :invalid_adapter}
    end
  end

  def register(_kind, _other), do: {:error, :invalid_adapter}

  @doc "Remove a binding kind from the registry."
  @spec unregister(atom()) :: :ok
  def unregister(kind) when is_atom(kind) do
    :persistent_term.put(@key, Map.delete(get_all(), kind))
    :ok
  end

  defp get_all, do: :persistent_term.get(@key, %{})
end

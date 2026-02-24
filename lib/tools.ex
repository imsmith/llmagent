defmodule LLMAgent.Tools do
  @moduledoc """
  Runtime registry of available tool modules for agent dispatch.

  Backed by `persistent_term` for fast reads. Built-in tools are seeded
  on application start via `init_registry/0`. Custom tools can be
  registered and unregistered at runtime.

  ## Examples

      iex> LLMAgent.Tools.bash()
      LLMAgent.Tools.Bash

      iex> LLMAgent.Tools.crypto()
      LLMAgent.Tools.Crypto

      iex> LLMAgent.Tools.all() |> Keyword.keys() |> Enum.sort()
      [:bash, :crypto, :dbus, :file, :inotify, :net, :proc, :systemd, :udev, :web]
  """

  @registry_key :llmagent_tools_registry

  alias LLMAgent.Tools.{
    Bash,
    Web,
    DBus,
    Systemd,
    Inotify,
    Udev,
    File,
    Net,
    Proc,
    Crypto
  }

  @builtins [
    bash: Bash,
    web: Web,
    dbus: DBus,
    systemd: Systemd,
    inotify: Inotify,
    udev: Udev,
    file: File,
    net: Net,
    proc: Proc,
    crypto: Crypto
  ]

  @doc """
  Seeds the registry with built-in tools. Called from Application.start.
  """
  @spec init_registry() :: :ok
  def init_registry do
    :persistent_term.put(@registry_key, Map.new(@builtins))
    :ok
  end

  @doc """
  Look up a tool module by name.

  ## Examples

      iex> LLMAgent.Tools.get(:bash)
      {:ok, LLMAgent.Tools.Bash}

      iex> LLMAgent.Tools.get(:nonexistent)
      {:error, :not_found}
  """
  @spec get(atom()) :: {:ok, module()} | {:error, :not_found}
  def get(name) do
    registry = :persistent_term.get(@registry_key, %{})

    case Map.fetch(registry, name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Look up a tool module by name, raising on failure.

  ## Examples

      iex> LLMAgent.Tools.get!(:bash)
      LLMAgent.Tools.Bash
  """
  @spec get!(atom()) :: module()
  def get!(name) do
    case get(name) do
      {:ok, module} -> module
      {:error, :not_found} -> raise "Tool #{name} not found in registry"
    end
  end

  @doc """
  Register a tool module at runtime. The module must export `perform/2`.

  ## Examples

      iex> LLMAgent.Tools.register(:bash, LLMAgent.Tools.Bash)
      :ok
      iex> LLMAgent.Tools.register(:bash, Enum)
      {:error, :invalid_tool}
  """
  @spec register(atom(), module()) :: :ok | {:error, :invalid_tool}
  def register(name, module) do
    Code.ensure_loaded(module)

    if function_exported?(module, :perform, 2) do
      registry = :persistent_term.get(@registry_key, %{})
      :persistent_term.put(@registry_key, Map.put(registry, name, module))
      :ok
    else
      {:error, :invalid_tool}
    end
  end

  @doc """
  Unregister a tool by name.

  ## Examples

      iex> LLMAgent.Tools.unregister(:nonexistent_tool)
      :ok
  """
  @spec unregister(atom()) :: :ok
  def unregister(name) do
    registry = :persistent_term.get(@registry_key, %{})
    :persistent_term.put(@registry_key, Map.delete(registry, name))
    :ok
  end

  @doc """
  Returns all registered tools as a keyword list of `{name, module}`.

  ## Examples

      iex> tools = LLMAgent.Tools.all()
      iex> Keyword.get(tools, :bash)
      LLMAgent.Tools.Bash
      iex> length(tools) >= 10
      true
  """
  @spec all() :: [{atom(), module()}]
  def all do
    :persistent_term.get(@registry_key, %{})
    |> Enum.to_list()
  end

  # Convenience functions — delegate to get!/1

  @doc "Returns the Bash tool module."
  @spec bash() :: module()
  def bash, do: get!(:bash)

  @doc "Returns the Web tool module."
  @spec web() :: module()
  def web, do: get!(:web)

  @doc "Returns the DBus tool module."
  @spec dbus() :: module()
  def dbus, do: get!(:dbus)

  @doc "Returns the Systemd tool module."
  @spec systemd() :: module()
  def systemd, do: get!(:systemd)

  @doc "Returns the Inotify tool module."
  @spec inotify() :: module()
  def inotify, do: get!(:inotify)

  @doc "Returns the Udev tool module."
  @spec udev() :: module()
  def udev, do: get!(:udev)

  @doc "Returns the File tool module."
  @spec file() :: module()
  def file, do: get!(:file)

  @doc "Returns the Net tool module."
  @spec net() :: module()
  def net, do: get!(:net)

  @doc "Returns the Proc tool module."
  @spec proc() :: module()
  def proc, do: get!(:proc)

  @doc "Returns the Crypto tool module."
  @spec crypto() :: module()
  def crypto, do: get!(:crypto)
end

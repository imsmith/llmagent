defmodule LLMAgent.Tools do
  @moduledoc """
  Registry of available tool modules for agent dispatch.

  Each function returns the module implementing `LLMAgent.Tool` for that tool name.

  ## Examples

      iex> LLMAgent.Tools.bash()
      LLMAgent.Tools.Bash

      iex> LLMAgent.Tools.crypto()
      LLMAgent.Tools.Crypto

      iex> LLMAgent.Tools.all() |> Keyword.keys()
      [:bash, :web, :dbus, :systemd, :inotify, :udev, :file, :net, :proc, :crypto]
  """

  @type tool_name ::
          :bash | :web | :dbus | :systemd | :inotify | :udev | :file | :net | :proc | :crypto

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

  @doc "Returns the Bash tool module."
  @spec bash() :: module()
  def bash, do: Bash

  @doc "Returns the Web tool module."
  @spec web() :: module()
  def web, do: Web

  @doc "Returns the DBus tool module."
  @spec dbus() :: module()
  def dbus, do: DBus

  @doc "Returns the Systemd tool module."
  @spec systemd() :: module()
  def systemd, do: Systemd

  @doc "Returns the Inotify tool module."
  @spec inotify() :: module()
  def inotify, do: Inotify

  @doc "Returns the Udev tool module."
  @spec udev() :: module()
  def udev, do: Udev

  @doc "Returns the File tool module."
  @spec file() :: module()
  def file, do: File

  @doc "Returns the Net tool module."
  @spec net() :: module()
  def net, do: Net

  @doc "Returns the Proc tool module."
  @spec proc() :: module()
  def proc, do: Proc

  @doc "Returns the Crypto tool module."
  @spec crypto() :: module()
  def crypto, do: Crypto

  @doc """
  Returns all available tools as a keyword list of `{name, module}`.

  ## Examples

      iex> tools = LLMAgent.Tools.all()
      iex> Keyword.get(tools, :bash)
      LLMAgent.Tools.Bash
      iex> length(tools)
      10
  """
  @spec all() :: [{tool_name(), module()}]
  def all do
    [
      bash: bash(),
      web: web(),
      dbus: dbus(),
      systemd: systemd(),
      inotify: inotify(),
      udev: udev(),
      file: file(),
      net: net(),
      proc: proc(),
      crypto: crypto()
    ]
  end
end

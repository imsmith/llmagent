defmodule LLMAgent.Tools.Builtins do
  @moduledoc """
  Registers all built-in tool ads with `LLMAgent.Tools.Discovery` at boot.

  Called from `LLMAgent.Application.start/2` immediately after the Discovery
  GenServer is in the supervision tree. Each tool module exposes `ad/0`
  returning its authoritative `%LLMAgent.ToolAd{}`; this module is just the
  enumeration point so adding a new built-in is a one-line change here plus
  the per-tool `ad/0` implementation.
  """

  alias LLMAgent.Tools

  @builtins [
    Tools.Crypto,
    Tools.Net,
    Tools.Proc,
    Tools.Inotify,
    Tools.Udev,
    Tools.File,
    Tools.Web,
    Tools.Systemd,
    Tools.DBus,
    Tools.TupleSpace,
    Tools.Agent,
    Tools.Bash
  ]

  @doc "Register every built-in tool's ad with `LLMAgent.Tools.Discovery`."
  @spec register_all() :: :ok
  def register_all do
    Enum.each(@builtins, fn mod ->
      :ok = LLMAgent.Tools.Discovery.register(mod.ad())
    end)
  end
end

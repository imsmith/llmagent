defmodule LLMAgent.DoctestTest do
  use ExUnit.Case, async: false

  # Core
  doctest LLMAgent.EventBus
  doctest LLMAgent.EventLog
  doctest LLMAgent.Events
  doctest LLMAgent.RolePrompt

  # Registries
  doctest LLMAgent.Tools
  doctest LLMAgent.Utils

  # Tools
  doctest LLMAgent.Tools.Bash
  doctest LLMAgent.Tools.Crypto
  doctest LLMAgent.Tools.File
  doctest LLMAgent.Tools.Net
  doctest LLMAgent.Tools.Proc
  doctest LLMAgent.Tools.DBus
  doctest LLMAgent.Tools.Systemd
  doctest LLMAgent.Tools.Udev
  doctest LLMAgent.Tools.Web
  doctest LLMAgent.Tools.Inotify
  doctest LLMAgent.Tools.Inotify.Watcher

  # Utilities
  doctest LLMAgent.Utils.Encoder
  doctest LLMAgent.Utils.Decoder
  doctest LLMAgent.Utils.Time
  doctest LLMAgent.Utils.RequireBinary
end

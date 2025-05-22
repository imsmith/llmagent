defmodule LLMAgent.Tools do
  @moduledoc """
  LLMAgent.Tools

  Provides a set of tools for AI Agents to interact with a Linux system and perform various tasks.

  Available tools:
		- `all/0`: Returns a list of all available tools.
    - `bash/0`: Interacts with the Linux Bash shell.
    - `web/0`: Interacts with the World Wide Web (API calls, browser simulation).
    - `dbus/0`: Interacts with the Linux D-Bus system.
    - `systemd/0`: Manages Linux services via systemd.
    - `inotify/0`: Monitors file system events using inotify.
    - `udev/0`: Interacts with the Linux udev device manager.
    - `file/0`: Provides file system operations.
		- `net/0`: Provides network operations.
		- `proc/0`: Provides process operations.
		- `crypto/0`: Provides cryptographic operations.
	Each tool is implemented as a module and can be used to perform specific tasks related to its functionality.
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

		@spec net() :: module()
		def net, do: Net

		@spec proc() :: module()
		def proc, do: Proc

		@spec crypto() :: module()
		def crypto, do: Crypto

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

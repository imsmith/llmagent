defmodule LLMAgent.Tools do

	@moduledoc """
	LLMAgent.Tools

	Provides a set of tools for AI Agents to interact with a Linux system and perform various tasks.

	Available tools:
	- `All/0`: Returns a list of all available tools.
	- `Bash/0`: Interacts with the Linux Bash shell.
	- `Web/0`: Interacts with the World Wide Web (API calls, browser simulation).
	- `Dbus/0`: Interacts with the Linux D-Bus system.
	- `Systemd/0`: Manages Linux services via systemd.
	- `Inotify/0`: Monitors file system events using inotify.
	- `Udev/0`: Interacts with the Linux udev device manager.
	- `File/0`: Provides file system operations.
	- `Net/0`: Provides network operations.
	- `Proc/0`: Provides process operations.
	- `Crypto/0`: Provides cryptographic operations.
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

		@spec bash() :: module()
		def bash, do: Bash

		@spec web() :: module()
		def web, do: Web

		@spec dbus() :: module()
		def dbus, do: DBus

		@spec systemd() :: module()
		def systemd, do: Systemd

		@spec inotify() :: module()
		def inotify, do: Inotify

		@spec udev() :: module()
		def udev, do: Udev

		@spec file() :: module()
		def file, do: File

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

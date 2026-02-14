defmodule LLMAgent.Tools.Udev do
  @moduledoc """
  Interacts with Linux udev for device management.

  Supported actions:
  - `"list"`: lists all block and USB devices
  - `"info"`: shows udev info for a specific device path
  - `"usb"`: lists USB devices
  - `"pci"`: lists PCI devices
  """

  @behaviour LLMAgent.Tool
  alias Comn.Errors.ErrorStruct

  @impl true
  def describe do
    """
    Lists and queries connected devices using Linux udev tools.

    Actions:
      - list: shows block and USB devices
      - info: get udev metadata for a device (requires "path")
      - usb: list USB devices
      - pci: list PCI devices
    """
  end

  @impl true
  def perform("list", _args) do
    {blk, _} = System.cmd("lsblk", ["-o", "NAME,SIZE,TYPE,MOUNTPOINT"], stderr_to_stdout: true)
    {usb, _} = System.cmd("lsusb", [], stderr_to_stdout: true)
    {:ok, %{output: %{block_devices: String.trim(blk), usb_devices: String.trim(usb)}, metadata: %{action: "list"}}}
  end

  def perform("info", %{"path" => path}) do
    case System.cmd("udevadm", ["info", "--query=all", "--name=#{path}"], stderr_to_stdout: true) do
      {out, 0} -> {:ok, %{output: String.trim(out), metadata: %{path: path}}}
      {out, code} -> {:error, ErrorStruct.new("command_failed", "path", "udevadm failed (exit #{code}): #{String.trim(out)}")}
    end
  end

  def perform("usb", _args) do
    case System.cmd("lsusb", [], stderr_to_stdout: true) do
      {out, 0} -> {:ok, %{output: String.trim(out), metadata: %{action: "usb"}}}
      {out, code} -> {:error, ErrorStruct.new("command_failed", "lsusb", "lsusb failed (exit #{code}): #{String.trim(out)}")}
    end
  end

  def perform("pci", _args) do
    case System.cmd("lspci", [], stderr_to_stdout: true) do
      {out, 0} -> {:ok, %{output: String.trim(out), metadata: %{action: "pci"}}}
      {out, code} -> {:error, ErrorStruct.new("command_failed", "lspci", "lspci failed (exit #{code}): #{String.trim(out)}")}
    end
  end

  def perform(_, _),
    do: {:error, ErrorStruct.new("unknown_command", nil, "Unrecognized Udev action")}
end

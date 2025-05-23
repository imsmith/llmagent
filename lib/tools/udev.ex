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
    {:ok, "Block Devices:\n#{blk}\nUSB Devices:\n#{usb}"}
  end

  def perform("info", %{"path" => path}) do
    System.cmd("udevadm", ["info", "--query=all", "--name=#{path}"], stderr_to_stdout: true)
    |> normalize()
  end

  def perform("usb", _args) do
    System.cmd("lsusb", [], stderr_to_stdout: true)
    |> normalize()
  end

  def perform("pci", _args) do
    System.cmd("lspci", [], stderr_to_stdout: true)
    |> normalize()
  end

  def perform(_, _), do: {:error, :unknown_command}

  defp normalize({out, 0}), do: {:ok, String.trim(out)}
  defp normalize({out, _}), do: {:error, String.trim(out)}
end

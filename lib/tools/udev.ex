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

  @doc """
  Returns a human-readable description of the Udev tool.

  ## Examples

      iex> LLMAgent.Tools.Udev.describe()
      ...> |> is_binary()
      true
  """
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

  @doc ~S"""
  Perform a udev/device action.

  ## Examples

      # List block and USB devices (returns structured data)
      {:ok, %{output: %{block_devices: blk, usb_devices: usb}}} =
        LLMAgent.Tools.Udev.perform("list", %{})
      # blk is a list of device maps, usb is a list of USB device maps

      # Get device info
      LLMAgent.Tools.Udev.perform("info", %{"path" => "/dev/sda"})

  Unknown action returns error:

      iex> {:error, %Comn.Errors.ErrorStruct{reason: "unknown_command"}} =
      ...>   LLMAgent.Tools.Udev.perform("nope", %{})
  """
  @impl true
  def perform("list", _args) do
    with {blk_json, 0} <- System.cmd("lsblk", ["-J", "-o", "NAME,SIZE,TYPE,MOUNTPOINT"], stderr_to_stdout: true),
         {usb_out, 0} <- System.cmd("lsusb", [], stderr_to_stdout: true) do
      block_devices = case Jason.decode(blk_json) do
        {:ok, %{"blockdevices" => devs}} -> devs
        _ -> blk_json
      end
      usb_devices = parse_lsusb(usb_out)
      {:ok, %{output: %{block_devices: block_devices, usb_devices: usb_devices}, metadata: %{action: "list"}}}
    else
      {err, code} ->
        {:error, ErrorStruct.new("command_failed", "udev", "Device listing failed (exit #{code}): #{String.trim(err)}")}
    end
  end

  def perform("info", %{"path" => path}) do
    case System.cmd("udevadm", ["info", "--query=all", "--name=#{path}"], stderr_to_stdout: true) do
      {out, 0} ->
        props = parse_udevadm(out)
        {:ok, %{output: props, metadata: %{path: path}}}
      {out, code} ->
        {:error, ErrorStruct.new("command_failed", "path", "udevadm failed (exit #{code}): #{String.trim(out)}")}
    end
  end

  def perform("usb", _args) do
    case System.cmd("lsusb", [], stderr_to_stdout: true) do
      {out, 0} -> {:ok, %{output: parse_lsusb(out), metadata: %{action: "usb"}}}
      {out, code} -> {:error, ErrorStruct.new("command_failed", "lsusb", "lsusb failed (exit #{code}): #{String.trim(out)}")}
    end
  end

  def perform("pci", _args) do
    case System.cmd("lspci", [], stderr_to_stdout: true) do
      {out, 0} -> {:ok, %{output: parse_lspci(out), metadata: %{action: "pci"}}}
      {out, code} -> {:error, ErrorStruct.new("command_failed", "lspci", "lspci failed (exit #{code}): #{String.trim(out)}")}
    end
  end

  def perform(_, _),
    do: {:error, ErrorStruct.new("unknown_command", nil, "Unrecognized Udev action")}

  defp parse_udevadm(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case line do
        "E: " <> kv ->
          case String.split(kv, "=", parts: 2) do
            [key, val] -> Map.put(acc, String.downcase(key), val)
            _ -> acc
          end
        "N: " <> name -> Map.put(acc, "devname", String.trim(name))
        "S: " <> link -> Map.update(acc, "symlinks", [String.trim(link)], &[String.trim(link) | &1])
        _ -> acc
      end
    end)
  end

  defp parse_lsusb(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case Regex.run(~r/Bus (\d+) Device (\d+): ID (\S+) (.*)/, line) do
        [_, bus, dev, id, desc] -> %{bus: bus, device: dev, id: id, description: String.trim(desc)}
        _ -> %{raw: String.trim(line)}
      end
    end)
  end

  defp parse_lspci(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case String.split(line, " ", parts: 2) do
        [slot, desc] -> %{slot: slot, description: String.trim(desc)}
        _ -> %{raw: String.trim(line)}
      end
    end)
  end
end

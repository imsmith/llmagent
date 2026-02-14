defmodule LLMAgent.Tools.DBus do
  @moduledoc """
  Provides access to Linux D-Bus messaging system using `busctl`.

  Supported actions:
  - `"list"` - lists all active bus services
  - `"introspect"` - introspects a service path
  - `"call"` - calls a method on a service interface
  """

  @behaviour LLMAgent.Tool
  alias Comn.Errors.ErrorStruct

  @impl true
  def describe do
    """
    Sends and receives messages over the Linux D-Bus.
    Actions:
      - list: returns all active services on the session or system bus
      - introspect: returns the interface XML of a service path
      - call: invokes a method on a D-Bus interface
    """
  end

  @impl true
  def perform("list", _args) do
    run_busctl(["list"], %{action: "list"})
  end

  def perform("introspect", %{"service" => svc, "path" => path}) do
    run_busctl(["introspect", svc, path], %{service: svc, path: path})
  end

  def perform("call", %{
        "service" => svc,
        "path" => path,
        "interface" => iface,
        "method" => method
      }) do
    run_busctl(["call", svc, path, iface, method], %{service: svc, path: path, interface: iface, method: method})
  end

  def perform(_, _),
    do: {:error, ErrorStruct.new("unknown_command", nil, "Unrecognized DBus action")}

  defp run_busctl(args, metadata) do
    case System.cmd("busctl", args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, %{output: String.trim(out), metadata: metadata}}
      {out, code} -> {:error, ErrorStruct.new("command_failed", "busctl", "busctl failed (exit #{code}): #{String.trim(out)}")}
    end
  end
end

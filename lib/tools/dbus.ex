defmodule LLMAgent.Tools.Dbus do
  @moduledoc """
  Provides access to Linux D-Bus messaging system using `busctl`.

  Supported actions:
  - `"list"` → lists all active bus services
  - `"introspect"` → introspects a service path
  - `"call"` → calls a method on a service interface
  """

  @behaviour LLMAgent.Tool

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
    System.cmd("busctl", ["list"], stderr_to_stdout: true)
    |> normalize()
  end

  def perform("introspect", %{"service" => svc, "path" => path}) do
    System.cmd("busctl", ["introspect", svc, path], stderr_to_stdout: true)
    |> normalize()
  end

  def perform("call", %{
        "service" => svc,
        "path" => path,
        "interface" => iface,
        "method" => method
      }) do
    System.cmd("busctl", ["call", svc, path, iface, method], stderr_to_stdout: true)
    |> normalize()
  end

  def perform(_, _), do: {:error, :unknown_command}

  defp normalize({out, 0}), do: {:ok, String.trim(out)}
  defp normalize({out, _}), do: {:error, String.trim(out)}
end

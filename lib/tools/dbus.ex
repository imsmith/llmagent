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

  @doc """
  Returns a human-readable description of the DBus tool.

  ## Examples

      iex> LLMAgent.Tools.DBus.describe()
      ...> |> is_binary()
      true
  """
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

  @doc ~S"""
  Perform a D-Bus action.

  ## Examples

      # List active services
      {:ok, %{output: listing, metadata: %{action: "list"}}} =
        LLMAgent.Tools.DBus.perform("list", %{})

      # Introspect a service
      LLMAgent.Tools.DBus.perform("introspect", %{
        "service" => "org.freedesktop.DBus",
        "path" => "/"
      })

  Unknown action returns error:

      iex> {:error, %Comn.Errors.ErrorStruct{reason: "unknown_command"}} =
      ...>   LLMAgent.Tools.DBus.perform("nope", %{})
  """
  @impl true
  def perform("list", _args) do
    case System.cmd("busctl", ["list", "--no-pager"], stderr_to_stdout: true) do
      {out, 0} ->
        services = parse_busctl_list(out)
        {:ok, %{output: services, metadata: %{action: "list", count: length(services)}}}
      {out, code} ->
        {:error, ErrorStruct.new("command_failed", "busctl", "busctl list failed (exit #{code}): #{String.trim(out)}")}
    end
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

  defp parse_busctl_list(text) do
    lines = String.split(text, "\n", trim: true)
    # Skip header line(s) — busctl list has a header row
    case lines do
      [_header | data_lines] ->
        Enum.map(data_lines, fn line ->
          parts = String.split(line, ~r/\s+/, trim: true)
          case parts do
            [name | rest] -> %{name: name, details: Enum.join(rest, " ")}
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      _ -> []
    end
  end
end

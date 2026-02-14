defmodule LLMAgent.Tools.Net do
  @moduledoc "Provides structured access to network interface, IP, and connectivity data."
  @behaviour LLMAgent.Tool
  alias Comn.Errors.ErrorStruct

  @impl true
  def describe do
    "Inspects network interfaces, IPs, DNS, and connectivity status."
  end

  @impl true
  def perform("list_interfaces", _args) do
    case System.cmd("ip", ["-j", "addr"], stderr_to_stdout: true) do
      {json, 0} ->
        case Jason.decode(json) do
          {:ok, data} -> {:ok, %{output: data, metadata: %{action: "list_interfaces"}}}
          {:error, _} -> {:ok, %{output: json, metadata: %{action: "list_interfaces", format: "raw"}}}
        end

      {err, code} ->
        {:error, ErrorStruct.new("command_failed", "ip", "ip addr failed (exit #{code}): #{String.trim(err)}")}
    end
  end

  def perform("ping", %{"host" => host}) do
    case System.cmd("ping", ["-c", "1", host], stderr_to_stdout: true) do
      {out, 0} -> {:ok, %{output: String.trim(out), metadata: %{host: host, reachable: true}}}
      {out, _} -> {:ok, %{output: String.trim(out), metadata: %{host: host, reachable: false}}}
    end
  end

  def perform("resolve", %{"host" => host}) do
    case System.cmd("dig", [host, "+short"], stderr_to_stdout: true) do
      {out, 0} ->
        addrs = out |> String.trim() |> String.split("\n", trim: true)
        {:ok, %{output: addrs, metadata: %{host: host}}}

      {err, code} ->
        {:error, ErrorStruct.new("command_failed", "host", "dig failed (exit #{code}): #{String.trim(err)}")}
    end
  end

  def perform(_, _),
    do: {:error, ErrorStruct.new("unknown_command", nil, "Unrecognized Net action")}
end

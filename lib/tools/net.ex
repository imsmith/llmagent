defmodule LLMAgent.Tools.Net do
  @moduledoc "Provides structured access to network interface, IP, and connectivity data."
  @behaviour LLMAgent.Tool

  @impl true
  def describe do
    "Inspects network interfaces, IPs, DNS, and connectivity status."
  end

  @impl true
  def perform("list_interfaces", _args) do
    case System.cmd("ip", ["-j", "addr"], stderr_to_stdout: true) do
      {json, 0} -> Jason.decode(json)
      {err, _} -> {:error, err}
    end
  end

  def perform("ping", %{"host" => host}) do
    System.cmd("ping", ["-c", "1", host], stderr_to_stdout: true)
  end

  def perform("resolve", %{"host" => host}) do
    System.cmd("dig", [host, "+short"], stderr_to_stdout: true)
  end

  def perform(_, _), do: {:error, :unknown_command}
end

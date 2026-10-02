defmodule LLMAgent.Tools.Net do
  @moduledoc "Provides structured access to network interface, IP, and connectivity data."
  @behaviour LLMAgent.Tool
  @behaviour LLMAgent.Tool.Kinds.Query
  alias Comn.Errors.ErrorStruct

  @doc """
  Returns a human-readable description of the Net tool.

  ## Examples

      iex> desc = LLMAgent.Tools.Net.describe()
      iex> desc =~ "list_interfaces"
      true
  """
  @impl true
  def describe do
    """
    Inspects network interfaces, IPs, DNS, and connectivity status.

    Actions:
      - list_interfaces: List all network interfaces with IP addresses.
        Args: none
        Example: {"tool": "net", "action": "list_interfaces", "args": {}}

      - ping: Ping a host and return reachability + round-trip time.
        Args: {"host": "<hostname or IP>"}
        Example: {"tool": "net", "action": "ping", "args": {"host": "8.8.8.8"}}

      - resolve: DNS-resolve a hostname to IP addresses.
        Args: {"host": "<hostname>"}
        Example: {"tool": "net", "action": "resolve", "args": {"host": "google.com"}}
    """
  end

  @doc ~S"""
  Perform a network action.

  ## Examples

      # List network interfaces
      {:ok, %{output: data, metadata: %{action: "list_interfaces"}}} =
        LLMAgent.Tools.Net.perform("list_interfaces", %{})

      # Ping a host (returns structured result with RTT)
      {:ok, %{output: %{reachable: true, rtt_ms: _, raw: _}, metadata: %{host: "localhost"}}} =
        LLMAgent.Tools.Net.perform("ping", %{"host" => "localhost"})

      # DNS resolve
      {:ok, %{output: addrs, metadata: %{host: "localhost"}}} =
        LLMAgent.Tools.Net.perform("resolve", %{"host" => "localhost"})

  Unknown action returns error:

      iex> {:error, %Comn.Errors.ErrorStruct{reason: "unknown_command"}} =
      ...>   LLMAgent.Tools.Net.perform("nope", %{})
  """
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
      {out, 0} ->
        rtt = parse_ping_rtt(out)
        {:ok, %{output: %{reachable: true, rtt_ms: rtt, raw: String.trim(out)}, metadata: %{host: host, reachable: true}}}
      {out, _} ->
        {:ok, %{output: %{reachable: false, rtt_ms: nil, raw: String.trim(out)}, metadata: %{host: host, reachable: false}}}
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

  @doc "Authoritative tool ad."
  @impl LLMAgent.Tool
  @spec ad() :: LLMAgent.ToolAd.t()
  def ad do
    actions = ~w(list_interfaces ping resolve)

    LLMAgent.ToolAd.new(%{
      id: "builtin.net",
      coordinate: "resource.network",
      kinds: [:query],
      binding: {:module, __MODULE__},
      operational: %{
        actions: Map.new(actions, &{&1, %{inputs: %{}, outputs: %{}, pre: nil, post: nil}})
      },
      constraint: %{
        idempotency: Map.new(actions, &{&1, :idempotent}),
        blast_radius: Map.new(actions, &{&1, :local})
      },
      affordance: %{
        declared: [
          %{intent: "inspect local network state", suits: "diagnostic and discovery flows", avoid_when: nil}
        ],
        learned: [],
        open: false
      },
      fidelity: :authoritative,
      provenance: %{source: "llmagent.builtin", produced_at: ~U[2026-05-18 00:00:00Z], based_on: [], signature: nil},
      lease: :permanent,
      meta: %{}
    })
  end

  @impl LLMAgent.Tool.Kinds.Query
  def query(action, args) do
    case perform(action, args) do
      {:ok, %{output: out, metadata: meta}} -> {:ok, out, meta}
      {:error, _} = err -> err
    end
  end

  defp parse_ping_rtt(output) do
    case Regex.run(~r|rtt min/avg/max/mdev = ([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)|, output) do
      [_, _min, avg, _max, _mdev] ->
        case Float.parse(avg) do
          {f, _} -> f
          :error -> nil
        end
      _ -> nil
    end
  end
end

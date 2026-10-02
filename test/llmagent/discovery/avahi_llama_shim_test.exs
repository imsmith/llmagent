defmodule LLMAgent.Discovery.AvahiLlamaShimTest do
  @moduledoc """
  The real `priv/discovery/avahi-llama.tcl`, run through `PortAdapter` the way
  a host application configures it, against a fake avahi source that prints
  recorded `avahi-browse` output and then stays open.

  The shim's unit tests (`test/tcl/avahi_llama_test.tcl`) cover what it emits
  for each line. This covers what only shows end to end: that the leases it
  issues are still alive in the registry after they would have expired.
  """

  use ExUnit.Case, async: false

  alias LLMAgent.Discovery.PortAdapter
  alias LLMAgent.Tools.Discovery, as: Reg
  alias LLMAgent.ToolQuery

  @fixture Path.expand("../../fixtures/discovery/avahi_llama_browse.txt", __DIR__)

  # Overridable so the suite can be pointed at a variant of the shim — used to
  # confirm this test fails against one that does not renew.
  defp shim, do: System.get_env("AVAHI_LLAMA_SHIM") || Path.expand("priv/discovery/avahi-llama.tcl")

  setup do
    Reg.reset!()
    tclsh = System.find_executable("tclsh")

    {:ok, pid} =
      PortAdapter.start_link(
        name: :test_avahi_llama,
        command: tclsh,
        args: [shim()],
        env: [
          {~c"AVAHI_LLAMA_BROWSE_CMD", String.to_charlist(~s(sh -c "cat #{@fixture}; exec sleep 30"))},
          {~c"AVAHI_LLAMA_RENEW_MS", ~c"200"},
          # One-second leases, so a test can outlive one.
          {~c"AVAHI_LLAMA_LEASE_S", ~c"1"}
        ]
      )

    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, adapter: pid}
  end

  defp llama_ads do
    {:ok, ads} = Reg.find_all(ToolQuery.new(%{coordinate: "compute.llm.chat"}))
    Enum.sort_by(ads, & &1.id)
  end

  defp await_ads(count, deadline_ms \\ 3_000) do
    cond do
      length(llama_ads()) == count -> llama_ads()
      deadline_ms <= 0 -> flunk("expected #{count} ads, have #{inspect(Enum.map(llama_ads(), & &1.id))}")
      true -> Process.sleep(50) && await_ads(count, deadline_ms - 50)
    end
  end

  defp resolved_hosts do
    @fixture
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "="))
    |> Enum.map(fn line ->
      parts = String.split(line, ";")
      "mdns:_llama._tcp:#{Enum.at(parts, 6)}:#{Enum.at(parts, 8)}"
    end)
    |> Enum.sort()
  end

  defp os_alive?(os_pid) do
    case File.read("/proc/#{os_pid}/stat") do
      {:ok, stat} ->
        {last_paren, 1} = stat |> :binary.matches(")") |> List.last()
        binary_part(stat, last_paren + 2, 1) != "Z"

      {:error, _} ->
        false
    end
  end

  defp await_death(os_pid, deadline_ms \\ 3_000) do
    cond do
      not os_alive?(os_pid) -> true
      deadline_ms <= 0 -> false
      true -> Process.sleep(50) && await_death(os_pid, deadline_ms - 50)
    end
  end

  defp children_of(os_pid) do
    case File.read("/proc/#{os_pid}/task/#{os_pid}/children") do
      {:ok, text} -> text |> String.split() |> Enum.map(&String.to_integer/1)
      {:error, _} -> []
    end
  end

  test "registers every host the source resolves" do
    assert Enum.map(await_ads(2), & &1.id) == resolved_hosts()
  end

  # Leases are stamped to the second, so the two readings are taken far enough
  # apart to cross one.
  test "keeps extending the leases it issued" do
    [first | _] = await_ads(2)
    {:expires_at, before} = first.lease

    Process.sleep(1_500)

    [again | _] = llama_ads()
    {:expires_at, later} = again.lease
    assert DateTime.compare(later, before) == :gt
  end

  # Each lease lasts one second here. Without renewal both ads would be gone
  # well before this sweep.
  test "its ads outlive their leases" do
    await_ads(2)
    Process.sleep(2_500)
    :ok = Reg.sweep_now()
    assert length(llama_ads()) == 2
  end

  test "stopping the adapter leaves neither the shim nor its source running", %{adapter: adapter} do
    await_ads(2)
    {:os_pid, shim_pid} = Port.info(:sys.get_state(adapter).port, :os_pid)
    [source_pid] = children_of(shim_pid)
    assert os_alive?(shim_pid) and os_alive?(source_pid)

    GenServer.stop(adapter)

    assert await_death(shim_pid), "shim #{shim_pid} survived"
    assert await_death(source_pid), "fake source #{source_pid} survived"
  end
end

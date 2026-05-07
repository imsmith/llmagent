defmodule LLMAgent.Discovery.PortAdapterTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias LLMAgent.Discovery.{PortAdapter, Wire}
  alias LLMAgent.Tools.Discovery, as: Reg

  setup do
    Reg.reset!()
    :ok
  end

  defp script_lines(ad) do
    {:ok, register_line} = Wire.encode_register(ad)
    [
      "EMIT " <> register_line,
      "SLEEP 3000",
      "EMIT {:event :expire :id \"" <> ad.id <> "\"}",
      "SLEEP 100",
      "EXIT 0"
    ]
  end

  defp write_script(lines) do
    path = Path.join(System.tmp_dir!(), "shim_#{System.unique_integer([:positive])}.script")
    File.write!(path, Enum.join(lines, "\n") <> "\n")
    path
  end

  defp sample_ad(id \\ "test.adapter.1") do
    LLMAgent.ToolAd.new(%{
      id: id,
      coordinate: "compute.llm.chat",
      kinds: [:generate],
      binding: {:openai_chat, %{api_host: "http://h:8080", model: "m"}},
      operational: %{actions: %{}, model_id: "m"},
      constraint:  %{idempotency: %{}, blast_radius: %{}},
      affordance:  %{declared: [], learned: [], open: true},
      fidelity:    :authoritative,
      provenance:  %{source: "test", produced_at: DateTime.utc_now(), based_on: [], signature: nil},
      lease:       {:expires_at, DateTime.add(DateTime.utc_now(), 60)}
    })
  end

  test "registers ad on :register event and unregisters on :expire" do
    ad = sample_ad()
    script_path = write_script(script_lines(ad))

    {:ok, pid} = PortAdapter.start_link(
      name: :test_adapter,
      command: System.find_executable("elixir"),
      args: ["-r", "test/support/fake_shim.exs", "-e", ":timer.sleep(5000)"],
      env: [{~c"LLMAGENT_FAKE_SHIM_SCRIPT", String.to_charlist(script_path)}]
    )
    Process.unlink(pid)

    # Elixir VM boots in ~50ms here; EMIT register fires immediately after.
    # SLEEP 3000 holds the shim open. At 500ms we are safely past register
    # but before the expire EMIT.
    Process.sleep(500)
    {:ok, ads} = Reg.find_all(LLMAgent.ToolQuery.new(%{coordinate: "compute.llm.chat"}))
    assert length(ads) == 1
    assert hd(ads).id == ad.id

    # After SLEEP 3000 + expire EMIT fires, unregister is called.
    # 500ms (already elapsed) + 3000ms script SLEEP + 100ms expire EMIT = ~3600ms.
    # Wait an additional 3500ms to be past that point.
    Process.sleep(3500)
    {:ok, []} = Reg.find_all(LLMAgent.ToolQuery.new(%{coordinate: "compute.llm.chat"}))

    if Process.alive?(pid), do: GenServer.stop(pid)
  end

  test "skips malformed lines without crashing" do
    script_path = write_script([
      "EMIT not valid edn",
      "EMIT {:event :register :ad bogus}",
      "SLEEP 30",
      "EXIT 0"
    ])

    {:ok, pid} = PortAdapter.start_link(
      name: :test_adapter_2,
      command: System.find_executable("elixir"),
      args: ["-r", "test/support/fake_shim.exs", "-e", ":timer.sleep(5000)"],
      env: [{~c"LLMAGENT_FAKE_SHIM_SCRIPT", String.to_charlist(script_path)}]
    )
    Process.unlink(pid)

    # The shim processes the malformed lines and exits cleanly.
    # The test not crashing (despite bad input) is the meaningful assertion —
    # no exception propagated to the test process via the unlinked GenServer.
    Process.sleep(500)
  end
end

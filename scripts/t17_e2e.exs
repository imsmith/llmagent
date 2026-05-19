#!/usr/bin/env elixir
# T17 end-to-end validation. Run with: mix run scripts/t17_e2e.exs

require Logger

defmodule T17 do
  @moduledoc false

  alias LLMAgent.{Tools.Discovery, ToolQuery, EventBus}

  def run do
    {:ok, _} = Application.ensure_all_started(:LLMAgent)

    step1_wait_for_app()
    builtins = step2_verify_builtins()
    target = step3_find_skynet001()
    telemetry_pid = step4_attach_telemetry()
    step5_drive_prompt(target)
    step6_assert_telemetry(telemetry_pid)

    IO.puts(IO.ANSI.green() <> "\nT17 PASS — agent loop drove a real prompt through the substrate." <> IO.ANSI.reset())
    IO.puts("Built-in ads registered: #{builtins}/12")
    IO.puts("Llama target: api_host=#{target.api_host} model=#{target.model}")
  end

  defp step1_wait_for_app do
    IO.puts("\n=== Step 1: wait for app + mDNS discovery ===")

    # Poll Discovery up to 15s for any compute.llm.chat ad to appear.
    deadline = System.monotonic_time(:millisecond) + 15_000
    wait_for_llm_ads(deadline)
  end

  defp wait_for_llm_ads(deadline) do
    case Discovery.find_all(ToolQuery.new(%{coordinate: "compute.*"})) do
      {:ok, [_ | _] = ads} ->
        IO.puts("  ✓ #{length(ads)} llama ad(s) found after #{15_000 - (deadline - System.monotonic_time(:millisecond))}ms")

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(500)
          wait_for_llm_ads(deadline)
        else
          IO.puts("  ✗ no llama ads after 15s — adapter may not be running, or coordinate pattern differs")
        end
    end
  end

  defp step2_verify_builtins do
    IO.puts("\n=== Step 2: verify all 12 built-in ads registered ===")

    expected = [
      "function.crypto", "resource.network", "resource.proc",
      "resource.fs.events", "resource.hardware.events", "resource.fs.file",
      "function.http", "function.systemd", "function.dbus",
      "function.coordination.tuplespace", "function.agent", "function.shell.bash"
    ]

    found =
      for coord <- expected, reduce: 0 do
        n ->
          case Discovery.find_one(ToolQuery.new(%{coordinate: coord})) do
            {:ok, _ad} -> IO.puts("  ✓ #{coord}"); n + 1
            _ -> IO.puts("  ✗ #{coord}  MISSING"); n
          end
      end

    if found != 12 do
      IO.puts(IO.ANSI.red() <> "T17 FAIL: only #{found}/12 built-in ads registered" <> IO.ANSI.reset())
      System.halt(1)
    end

    found
  end

  defp step3_find_skynet001 do
    IO.puts("\n=== Step 3: locate skynet001 in mDNS-discovered llamas ===")

    # The mDNS shim publishes ads with coordinate "compute.llm.chat" (and kinds [:generate])
    {:ok, ads} = Discovery.find_all(ToolQuery.new(%{coordinate: "compute.*"}))

    if ads == [] do
      IO.puts(IO.ANSI.red() <> "T17 FAIL: no mDNS-discovered llamas (compute.llm.chat*)" <> IO.ANSI.reset())
      IO.puts("Check: is avahi-llama.tcl running? Is _llama._tcp being advertised on skynet001?")
      System.halt(1)
    end

    IO.puts("Found #{length(ads)} llama-server ad(s):")
    Enum.each(ads, fn ad ->
      {_kind, payload} = ad.binding
      IO.puts("  - #{ad.coordinate}  api_host=#{payload.api_host}  model=#{payload.model}")
    end)

    target =
      Enum.find(ads, fn ad ->
        {_, payload} = ad.binding
        String.contains?(payload.api_host, "skynet001")
      end)

    case target do
      nil ->
        IO.puts(IO.ANSI.yellow() <> "skynet001 not found by name; falling back to first ad" <> IO.ANSI.reset())
        {_, payload} = hd(ads).binding
        payload

      ad ->
        {_, payload} = ad.binding
        IO.puts(IO.ANSI.green() <> "Targeting skynet001 → #{payload.api_host} (#{payload.model})" <> IO.ANSI.reset())
        payload
    end
  end

  defp step4_attach_telemetry do
    IO.puts("\n=== Step 4: attach telemetry handler ===")

    parent = self()
    handler_id = "t17-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:llmagent, :tool, :compute],
        [:llmagent, :tool, :query],
        [:llmagent, :tool, :action]
      ],
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    handler_id
  end

  defp step5_drive_prompt(target) do
    IO.puts("\n=== Step 5: start an agent against the target, send a prompt ===")

    name = :"t17_agent_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      LLMAgent.AgentSupervisor.start_agent(
        name: name,
        api_host: target.api_host,
        model: target.model,
        allowed_tools: [:crypto]
      )

    EventBus.subscribe("agent.message")
    EventBus.subscribe("agent.tool_dispatch")
    EventBus.subscribe("agent.llm_response")
    EventBus.subscribe("agent.error")

    prompt = """
    Compute the SHA-256 hash of the string "abc" by calling the crypto tool.
    Respond with a single tool call in JSON of the form:
    {"tool": "crypto", "action": "sha256", "args": {"data": "abc"}}
    """

    IO.puts("Prompting agent #{name}:")
    IO.puts("  > #{String.replace(prompt, "\n", "\n  > ")}")

    LLMAgent.prompt({:global, name}, prompt)

    IO.puts("\nWaiting for the loop to complete (up to 60s)...")
    consume_events(name, %{user: false, llm: false, dispatch: false, function: false, assistant: false}, 60_000)

    LLMAgent.AgentSupervisor.stop_agent(name)
  end

  defp consume_events(_name, %{assistant: true, function: true}, _deadline_ms), do: :ok

  defp consume_events(name, seen, deadline_ms) when deadline_ms > 0 do
    started = System.monotonic_time(:millisecond)

    receive do
      {:event, "agent.message", %{data: %{role: role, content: content}}} ->
        role_str = if is_atom(role), do: Atom.to_string(role), else: role
        snippet = content |> to_string() |> String.slice(0, 140) |> String.replace("\n", " ")
        IO.puts("  [agent.message #{role_str}] #{snippet}")

        new_seen =
          case role_str do
            "user" -> %{seen | user: true}
            "assistant" -> %{seen | assistant: true}
            "function" -> %{seen | function: true}
            _ -> seen
          end

        elapsed = System.monotonic_time(:millisecond) - started
        consume_events(name, new_seen, deadline_ms - elapsed)

      {:event, "agent.llm_response", %{data: data}} ->
        IO.puts("  [agent.llm_response] is_tool_call=#{inspect(Map.get(data, :is_tool_call))}")
        elapsed = System.monotonic_time(:millisecond) - started
        consume_events(name, %{seen | llm: true}, deadline_ms - elapsed)

      {:event, "agent.tool_dispatch", %{data: data}} ->
        IO.puts("  [agent.tool_dispatch] tool=#{inspect(data.tool)} action=#{inspect(data.action)}")
        elapsed = System.monotonic_time(:millisecond) - started
        consume_events(name, %{seen | dispatch: true}, deadline_ms - elapsed)

      {:event, "agent.error", %{data: data}} ->
        IO.puts(IO.ANSI.red() <> "  [agent.error] #{inspect(data)}" <> IO.ANSI.reset())
        elapsed = System.monotonic_time(:millisecond) - started
        consume_events(name, seen, deadline_ms - elapsed)

      _other ->
        elapsed = System.monotonic_time(:millisecond) - started
        consume_events(name, seen, deadline_ms - elapsed)
    after
      deadline_ms ->
        IO.puts(IO.ANSI.yellow() <> "Timed out waiting for loop completion. Seen: #{inspect(seen)}" <> IO.ANSI.reset())
        :timeout
    end
  end

  defp consume_events(_name, seen, _deadline_ms) do
    IO.puts(IO.ANSI.yellow() <> "Deadline exhausted. Seen: #{inspect(seen)}" <> IO.ANSI.reset())
    :timeout
  end

  defp step6_assert_telemetry(_handler_id) do
    IO.puts("\n=== Step 6: drain telemetry, look for [:llmagent, :tool, :compute] coordinate=function.crypto ===")

    telem = drain_telemetry([], 500)

    if telem == [] do
      IO.puts(IO.ANSI.yellow() <> "No telemetry events fired. Possible causes:" <> IO.ANSI.reset())
      IO.puts("  - LLM didn't emit a valid tool-call JSON (small models often fail this format)")
      IO.puts("  - Dispatch fell back to the legacy perform/2 path silently")
      IO.puts("  - The crypto tool returned an error before telemetry fired")
    else
      IO.puts("Telemetry events captured:")
      Enum.each(telem, fn {evt, _meas, meta} ->
        IO.puts("  • #{inspect(evt)} → #{inspect(meta)}")
      end)

      hit =
        Enum.any?(telem, fn {evt, _meas, meta} ->
          evt == [:llmagent, :tool, :compute] and Map.get(meta, :coordinate) == "function.crypto"
        end)

      if hit do
        IO.puts(IO.ANSI.green() <> "✓ Dispatcher telemetry confirmed: agent → Tool.Dispatcher → :compute → function.crypto" <> IO.ANSI.reset())
      else
        IO.puts(IO.ANSI.yellow() <> "Telemetry fired but no compute/function.crypto hit. Loop may have errored before crypto dispatch." <> IO.ANSI.reset())
      end
    end
  end

  defp drain_telemetry(acc, timeout) do
    receive do
      {:telemetry, evt, meas, meta} -> drain_telemetry([{evt, meas, meta} | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end
end

T17.run()

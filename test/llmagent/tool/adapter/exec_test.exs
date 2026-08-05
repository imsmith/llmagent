defmodule LLMAgent.Tool.Adapter.ExecTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias LLMAgent.{ToolAd, Tool.Adapter.Exec}

  setup do
    dir = Path.join(System.tmp_dir!(), "exec_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  # Writes an executable fixture and returns its path.
  defp fixture(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end

  # An ad permissive enough that Task 5's guards will not refuse it.
  defp ad_for(path, arity \\ 0, variadic \\ true) do
    ToolAd.new(%{
      id: "bin:#{path}",
      coordinate: "command.local.fixture",
      kinds: [:action],
      binding: {:exec, %{argv: [path], interpreter: "bash"}},
      operational: %{actions: %{"run" => %{arity: arity, variadic: variadic}}},
      constraint: %{idempotency: %{}, blast_radius: %{scope: :none}},
      affordance: %{declared: [], learned: [], open: true},
      fidelity: :speculative,
      provenance: %{source: "test", produced_at: ~U[2026-08-05 00:00:00Z], based_on: [], signature: nil},
      lease: :permanent,
      meta: %{extraction: :complete, language: "bash"}
    })
  end

  defp call(path, args, extra_opts \\ [], ad \\ nil) do
    ad = ad || ad_for(path)
    payload = %{argv: [path], interpreter: "bash"}
    Exec.act(payload, "run", args, nil, [{:ad, ad} | extra_opts])
  end

  # A killed child stays in /proc as a zombie until the VM reaps it, so
  # existence alone is not liveness — read the state field out of stat.
  # (Same technique as test/llmagent/discovery/port_adapter_test.exs.)
  defp os_alive?(os_pid) do
    case File.read("/proc/#{os_pid}/stat") do
      {:ok, stat} ->
        state = stat |> String.split(") ") |> List.last() |> String.first()
        state != "Z"

      {:error, _} ->
        false
    end
  end

  # `Exec.act/5` does not hand back the os_pid it spawned, so to check that a
  # timed-out process is actually gone we scan /proc for any process whose
  # cmdline still mentions the fixture's (unique, per-test) path.
  defp survivors(path) do
    File.ls!("/proc")
    |> Enum.filter(&Regex.match?(~r/^\d+$/, &1))
    |> Enum.filter(fn pid ->
      case File.read("/proc/#{pid}/cmdline") do
        {:ok, cmdline} -> String.contains?(cmdline, path)
        {:error, _} -> false
      end
    end)
  end

  # Polls instead of asserting on `reap/1`'s return alone: `reap` blocks for
  # its grace period and signals KILL, but the OS still needs a moment to
  # actually tear the process down and flip its /proc state to zombie.
  # (Same technique as test/llmagent/discovery/port_adapter_test.exs.)
  defp await_death(os_pid, deadline_ms \\ 3000) do
    cond do
      not os_alive?(os_pid) -> true
      deadline_ms <= 0 -> false
      true -> Process.sleep(50) && await_death(os_pid, deadline_ms - 50)
    end
  end

  test "runs a command and returns its output", %{dir: dir} do
    path = fixture(dir, "hello.sh", "#!/bin/bash\necho hello\n")
    assert {:ok, output, meta} = call(path, %{})
    assert output =~ "hello"
    assert meta.status == 0
    assert meta.truncated == false
    assert is_integer(meta.duration_ms)
  end

  test "passes positional arguments through", %{dir: dir} do
    path = fixture(dir, "args.sh", "#!/bin/bash\nprintf '%s|' \"$@\"\n")
    assert {:ok, output, _meta} = call(path, %{"args" => ["a", "b c"]})
    assert output == "a|b c|"
  end

  test "merges stderr into the output", %{dir: dir} do
    path = fixture(dir, "err.sh", "#!/bin/bash\necho to-stderr >&2\n")
    assert {:ok, output, _meta} = call(path, %{})
    assert output =~ "to-stderr"
  end

  test "a non-zero exit is an error carrying the output", %{dir: dir} do
    path = fixture(dir, "fail.sh", "#!/bin/bash\necho nope\nexit 3\n")
    assert {:error, {:exit_status, 3, output}} = call(path, %{})
    assert output =~ "nope"
  end

  # The whole point of argv execution: shell metacharacters are inert data.
  test "arguments are never interpreted by a shell", %{dir: dir} do
    canary = Path.join(dir, "pwned")
    path = fixture(dir, "echo.sh", "#!/bin/bash\nprintf '%s' \"$1\"\n")

    assert {:ok, output, _meta} = call(path, %{"args" => ["; touch #{canary}"]})

    assert output == "; touch #{canary}"
    refute File.exists?(canary)
  end

  test "a file with no shebang runs under sh", %{dir: dir} do
    path = fixture(dir, "noshebang", "echo bare\n")
    ad = %{ad_for(path) | meta: %{extraction: :complete, no_shebang: true}}
    assert {:ok, output, _meta} = call(path, %{}, [], ad)
    assert output =~ "bare"
  end

  # A process that emits output faster than the timeout can never trip an
  # idle/inactivity timeout — each chunk would reset the clock. exec_timeout
  # must bound total wall-clock runtime instead, or tools like `pv` (named in
  # the moduledoc) would run forever.
  test "kills the process on a total wall-clock timeout, even with continuous output",
       %{dir: dir} do
    path = fixture(dir, "chatty.sh", "#!/bin/bash\nwhile true; do echo tick; sleep 0.05; done\n")

    started = System.monotonic_time(:millisecond)
    assert {:error, {:timeout, 400, _output}} = call(path, %{}, exec_timeout: 400)
    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed < 3_000,
           "timeout took #{elapsed}ms; an idle-reset timeout would never fire " <>
             "against continuous output, so this bounds for a total-budget timeout only"

    refute survivors(path) |> Enum.any?(&os_alive?/1),
           "chatty.sh OS process(es) survived the exec timeout"
  end

  # The port must not be opened in the caller's process. On a timeout the
  # dying child's remaining {port, {:data, _}} chunks and its
  # {port, {:exit_status, 143}} are delivered *after* collection gives up; if
  # the caller owned the port they would sit unmatched in its mailbox. The
  # intended consumer is a GenServer, and `LLMAgent`'s `handle_info/2` has no
  # catch-all clause, so one such message is a FunctionClauseError and a dead
  # agent. ExUnit test processes tolerate stray mail silently, which is why
  # this has to be asserted rather than observed.
  test "a timeout leaves no stray port messages in the caller's mailbox", %{dir: dir} do
    path = fixture(dir, "noisy.sh", "#!/bin/bash\nwhile true; do echo tick; sleep 0.02; done\n")

    assert {:error, {:timeout, 300, _output}} = call(path, %{}, exec_timeout: 300)

    # Well past reap's 200 ms grace, so anything the child emitted on its way
    # out has had time to be delivered.
    Process.sleep(500)

    assert drain_mailbox() == [],
           "exec left messages in the calling process's mailbox after a timeout"
  end

  test "the mailbox is also clean after a successful run", %{dir: dir} do
    path = fixture(dir, "ok.sh", "#!/bin/bash\necho done\n")
    assert {:ok, _output, _meta} = call(path, %{})
    Process.sleep(100)
    assert drain_mailbox() == []
  end

  # If the caller dies while output collection is blocked, nothing in the BEAM
  # signals the OS process: Port.close/1 closes pipes, it does not kill. The
  # child survives holding the stdout it inherited — the failure OSProcess's
  # moduledoc exists to describe.
  test "a caller that dies mid-run does not orphan the OS process", %{dir: dir} do
    path = fixture(dir, "orphan.sh", "#!/bin/bash\necho $$ > #{dir}/pidfile\nsleep 60\n")
    ad = ad_for(path)
    payload = %{argv: [path], interpreter: "bash"}

    {caller, ref} =
      spawn_monitor(fn ->
        Exec.act(payload, "run", %{}, nil, ad: ad, exec_timeout: 30_000)
      end)

    os_pid = await_pidfile(Path.join(dir, "pidfile"))
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}, 1_000

    assert await_death(os_pid),
           "orphan.sh OS process #{os_pid} outlived the process that started it"
  end

  defp drain_mailbox(acc \\ []) do
    receive do
      msg -> drain_mailbox([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp await_pidfile(path, deadline_ms \\ 5_000) do
    case File.read(path) do
      {:ok, contents} ->
        case contents |> String.trim() |> Integer.parse() do
          {pid, _} -> pid
          :error -> retry_pidfile(path, deadline_ms)
        end

      {:error, _} ->
        retry_pidfile(path, deadline_ms)
    end
  end

  defp retry_pidfile(path, deadline_ms) do
    if deadline_ms <= 0 do
      flunk("fixture never wrote #{path}")
    else
      Process.sleep(50)
      await_pidfile(path, deadline_ms - 50)
    end
  end

  test "an unknown action is refused", %{dir: dir} do
    path = fixture(dir, "hello.sh", "#!/bin/bash\necho hello\n")
    payload = %{argv: [path], interpreter: "bash"}
    assert {:error, {:unknown_action, "frobnicate"}} =
             Exec.act(payload, "frobnicate", %{}, nil, ad: ad_for(path))
  end

  # Unlike the continuous-output timeout test above, this shim is silent after
  # its first line: it writes its own pid, then blocks in `sleep` producing no
  # further output at all. A timeout that only fires on inactivity between
  # chunks would never distinguish this from a hang; the total-budget timeout
  # must fire here too.
  test "a silent, long-running command is killed on timeout", %{dir: dir} do
    path = fixture(dir, "slow.sh", "#!/bin/bash\necho $$ > #{dir}/pidfile\nsleep 60\n")

    assert {:error, {:timeout, 400, _partial}} =
             call(path, %{}, exec_timeout: 400)

    os_pid = dir |> Path.join("pidfile") |> File.read!() |> String.trim() |> String.to_integer()

    assert await_death(os_pid),
           "slow.sh OS process #{os_pid} survived the exec timeout"
  end

  test "the timeout error carries whatever output arrived first", %{dir: dir} do
    path = fixture(dir, "chatty.sh", "#!/bin/bash\necho early\nsleep 60\n")

    assert {:error, {:timeout, _, partial}} = call(path, %{}, exec_timeout: 600)
    assert partial =~ "early"
  end

  test "output past the cap is truncated and flagged", %{dir: dir} do
    # 300 KB, comfortably past the 256 KB cap.
    path = fixture(dir, "loud.sh", "#!/bin/bash\nhead -c 307200 /dev/zero | tr '\\0' 'x'\n")

    assert {:ok, output, meta} = call(path, %{})
    assert meta.truncated == true
    assert byte_size(output) == 262_144
  end

  test "output under the cap is not flagged", %{dir: dir} do
    path = fixture(dir, "quiet.sh", "#!/bin/bash\necho small\n")
    assert {:ok, _output, meta} = call(path, %{})
    assert meta.truncated == false
  end

  describe "guards" do
    test "an exact-arity tool refuses the wrong argument count", %{dir: dir} do
      path = fixture(dir, "one.sh", "#!/bin/bash\necho \"$1\"\n")
      ad = ad_for(path, 1, false)

      assert {:error, {:arity_mismatch, [expected: 1, got: 2]}} =
               call(path, %{"args" => ["a", "b"]}, [], ad)

      assert {:error, {:arity_mismatch, [expected: 1, got: 0]}} =
               call(path, %{}, [], ad)

      assert {:ok, _out, _meta} = call(path, %{"args" => ["a"]}, [], ad)
    end

    test "a variadic tool treats arity as a minimum", %{dir: dir} do
      path = fixture(dir, "many.sh", "#!/bin/bash\nprintf '%s|' \"$@\"\n")
      ad = ad_for(path, 1, true)

      assert {:error, {:arity_mismatch, [expected: 1, got: 0]}} = call(path, %{}, [], ad)
      assert {:ok, _out, _meta} = call(path, %{"args" => ["a"]}, [], ad)
      assert {:ok, _out, _meta} = call(path, %{"args" => ["a", "b", "c"]}, [], ad)
    end

    test "a :system blast radius is refused, and lifts with an opt", %{dir: dir} do
      path = fixture(dir, "sys.sh", "#!/bin/bash\necho ran\n")
      ad = %{ad_for(path) | constraint: %{idempotency: %{}, blast_radius: %{scope: :system}}}

      assert {:error, {:refused, :blast_radius, :system}} = call(path, %{}, [], ad)

      assert {:ok, output, _meta} =
               call(path, %{}, [exec_allow_blast_radius: [:system]], ad)

      assert output =~ "ran"
    end

    test "an :unknown blast radius is refused", %{dir: dir} do
      path = fixture(dir, "unk.sh", "#!/bin/bash\necho ran\n")
      ad = %{ad_for(path) | constraint: %{idempotency: %{}, blast_radius: %{scope: :unknown}}}
      assert {:error, {:refused, :blast_radius, :unknown}} = call(path, %{}, [], ad)
    end

    test "a missing blast radius is refused, not permitted", %{dir: dir} do
      path = fixture(dir, "none.sh", "#!/bin/bash\necho ran\n")
      ad = %{ad_for(path) | constraint: %{idempotency: %{}}}
      assert {:error, {:refused, :blast_radius, :unknown}} = call(path, %{}, [], ad)
    end

    test "incomplete extraction is refused, and lifts with an opt", %{dir: dir} do
      path = fixture(dir, "inc.sh", "#!/bin/bash\necho ran\n")
      ad = %{ad_for(path) | meta: %{extraction: :incomplete}}

      assert {:error, {:refused, :extraction, :incomplete}} = call(path, %{}, [], ad)

      assert {:ok, _out, _meta} =
               call(path, %{}, [exec_allow_extraction: [:incomplete]], ad)
    end

    test "unsupported extraction is refused", %{dir: dir} do
      path = fixture(dir, "uns.sh", "#!/bin/bash\necho ran\n")
      ad = %{ad_for(path) | meta: %{extraction: :unsupported}}
      assert {:error, {:refused, :extraction, :unsupported}} = call(path, %{}, [], ad)
    end

    test "a missing extraction signal is refused", %{dir: dir} do
      path = fixture(dir, "nometa.sh", "#!/bin/bash\necho ran\n")
      ad = %{ad_for(path) | meta: %{}}
      assert {:error, {:refused, :extraction, :unknown}} = call(path, %{}, [], ad)
    end

    test "blast radius is checked before extraction", %{dir: dir} do
      path = fixture(dir, "both.sh", "#!/bin/bash\necho ran\n")

      ad = %{
        ad_for(path)
        | constraint: %{idempotency: %{}, blast_radius: %{scope: :system}},
          meta: %{extraction: :incomplete}
      }

      assert {:error, {:refused, :blast_radius, :system}} = call(path, %{}, [], ad)
    end

    test "a missing action spec refuses even a zero-argument call", %{dir: dir} do
      path = fixture(dir, "noaction.sh", "#!/bin/bash\necho ran\n")
      ad = %{ad_for(path) | operational: %{actions: %{}}}
      assert {:error, {:refused, :arity, :unknown}} = call(path, %{}, [], ad)
    end

    test "an operational map with no actions key at all refuses", %{dir: dir} do
      path = fixture(dir, "noactionskey.sh", "#!/bin/bash\necho ran\n")
      ad = %{ad_for(path) | operational: %{}}
      assert {:error, {:refused, :arity, :unknown}} = call(path, %{}, [], ad)
    end

    test "an out-of-vocabulary blast radius scope is refused", %{dir: dir} do
      path = fixture(dir, "host.sh", "#!/bin/bash\necho ran\n")
      ad = %{ad_for(path) | constraint: %{idempotency: %{}, blast_radius: %{scope: :host}}}
      assert {:error, {:refused, :blast_radius, :host}} = call(path, %{}, [], ad)
    end

    test "a :filesystem blast radius proceeds", %{dir: dir} do
      path = fixture(dir, "fs.sh", "#!/bin/bash\necho ran\n")
      ad = %{ad_for(path) | constraint: %{idempotency: %{}, blast_radius: %{scope: :filesystem}}}
      assert {:ok, output, _meta} = call(path, %{}, [], ad)
      assert output =~ "ran"
    end

    test "an out-of-vocabulary extraction value is refused", %{dir: dir} do
      path = fixture(dir, "partial.sh", "#!/bin/bash\necho ran\n")
      ad = %{ad_for(path) | meta: %{extraction: :partial}}
      assert {:error, {:refused, :extraction, :partial}} = call(path, %{}, [], ad)
    end

    test "a non-list args value is refused, not raised", %{dir: dir} do
      path = fixture(dir, "badargs.sh", "#!/bin/bash\necho ran\n")
      assert {:error, {:refused, :arity, :unknown}} =
               call(path, %{"args" => "not a list"}, [], ad_for(path))
    end

    test "a {:ref, coord} meta is refused, not raised", %{dir: dir} do
      path = fixture(dir, "refmeta.sh", "#!/bin/bash\necho ran\n")
      ad = %{ad_for(path) | meta: {:ref, "some.coord"}}
      assert {:error, {:refused, :extraction, :unknown}} = call(path, %{}, [], ad)
    end

    test "a {:ref, coord} constraint is refused", %{dir: dir} do
      path = fixture(dir, "refconstraint.sh", "#!/bin/bash\necho ran\n")
      ad = %{ad_for(path) | constraint: {:ref, "some.coord"}}
      assert {:error, {:refused, :blast_radius, :unknown}} = call(path, %{}, [], ad)
    end

    # Keeping only List.first(argv) would turn this into "run the interpreter
    # with model-controlled arguments" — arbitrary execution wearing one
    # script's coordinate.
    test "the whole binding argv is the command prefix, not just its head", %{dir: dir} do
      script = fixture(dir, "prefixed.sh", "#!/bin/bash\nprintf '%s|' \"$@\"\n")
      env = System.find_executable("env")

      ad = %{ad_for(script) | binding: {:exec, %{argv: [env, script], interpreter: "bash"}}}
      payload = %{argv: [env, script], interpreter: "bash"}

      assert {:ok, output, _meta} =
               Exec.act(payload, "run", %{"args" => ["a", "b"]}, nil, ad: ad)

      assert output == "a|b|"
    end

    test "a payload with no argv is refused, not raised", %{dir: dir} do
      path = fixture(dir, "noargv.sh", "#!/bin/bash\necho ran\n")

      assert {:error, {:refused, :binding, :malformed}} =
               Exec.act(%{interpreter: "bash"}, "run", %{}, nil, ad: ad_for(path))
    end

    test "a payload with an empty or non-binary argv head is refused", %{dir: dir} do
      path = fixture(dir, "badargv.sh", "#!/bin/bash\necho ran\n")
      ad = ad_for(path)

      assert {:error, {:refused, :binding, :malformed}} =
               Exec.act(%{argv: [], interpreter: "bash"}, "run", %{}, nil, ad: ad)

      assert {:error, {:refused, :binding, :malformed}} =
               Exec.act(%{argv: [:not_a_path], interpreter: "bash"}, "run", %{}, nil, ad: ad)
    end

    # sh would otherwise read a path beginning with `-` as an option, and
    # `sh -c <args>` is the one place in this module a shell is reachable.
    test "the no-shebang path passes -- before a dash-leading script name", %{dir: dir} do
      canary = Path.join(dir, "pwned")
      fixture(dir, "-c", "printf '%s' \"$1\"\n")

      # A *relative* argv head, so the leading `-` actually reaches sh as
      # something that looks like an option.
      ad = %{ad_for("-c") | meta: %{extraction: :complete, no_shebang: true}}
      payload = %{argv: ["-c"], interpreter: "sh"}

      Exec.act(payload, "run", %{"args" => ["touch #{canary}"]}, nil, ad: ad, exec_cd: dir)

      refute File.exists?(canary), "sh interpreted the argument as shell input"
    end

    test "arity is checked before blast radius", %{dir: dir} do
      path = fixture(dir, "arityfirst.sh", "#!/bin/bash\necho ran\n")

      ad = %{
        ad_for(path, 1, false)
        | constraint: %{idempotency: %{}, blast_radius: %{scope: :system}}
      }

      assert {:error, {:arity_mismatch, [expected: 1, got: 0]}} = call(path, %{}, [], ad)
    end
  end
end

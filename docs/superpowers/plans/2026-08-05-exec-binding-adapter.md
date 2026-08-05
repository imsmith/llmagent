# `:exec` Binding Adapter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the 32 commands discovered by `bin-watch.tcl` invocable through `LLMAgent.Tool.Dispatcher`, behind guards derived from each ad's own honesty signals.

**Architecture:** A new `LLMAgent.Tool.Adapter.Exec` implements only the `act/5` callback of `LLMAgent.Tool.Adapter`. It spawns the target executable as an Erlang `Port` with an argv list — never through a shell — and refuses calls whose ad reports a dangerous blast radius or an incomplete static reading. `Dispatcher` is changed to pass the resolved ad to adapters via `opts`, since guards need ad fields the binding payload does not carry.

**Tech Stack:** Elixir 1.19.5 / OTP 28, ExUnit, `tcltest` 2.5 for the Tcl shim, Erlang ports.

## Global Constraints

- Never construct a shell command string. All execution is argv-based via `Port.open({:spawn_executable, ...}, [{:args, ...}])`.
- Default timeout is `30_000` ms. Output cap is `262_144` bytes (256 KB). SIGTERM-to-SIGKILL grace is `200` ms.
- The only valid action name is `"run"`.
- A missing safety signal is treated as `:unknown` and refused — never as permission.
- Full spec: `docs/superpowers/specs/2026-08-05-exec-binding-adapter-design.md`.
- Commit messages in this repo are plain imperative sentences, not Conventional Commits. Match that style.
- Tests that inspect OS processes read `/proc/<pid>/stat`; this repo targets Linux and Alpine containers.

---

### Task 1: Extract `LLMAgent.OSProcess`

`PortAdapter` grew a private TERM/grace/KILL sequence on 2026-08-05. The exec adapter needs the identical behaviour on timeout. Extract it once.

**Files:**

- Create: `lib/llmagent/os_process.ex`
- Create: `test/llmagent/os_process_test.exs`
- Modify: `lib/llmagent/discovery/port_adapter.ex` (remove private `reap/1`, `signal/2`, `os_alive?/1`; call `OSProcess` instead)

**Interfaces:**

- Consumes: nothing.
- Produces: `LLMAgent.OSProcess.alive?(os_pid :: non_neg_integer()) :: boolean()` and `LLMAgent.OSProcess.reap(os_pid :: non_neg_integer() | nil, grace_ms :: non_neg_integer()) :: :ok`. `reap/2` has a default of `200` for `grace_ms`, so `reap/1` is also callable. `reap(nil, _)` returns `:ok`.

- [ ] **Step 1: Write the failing test**

Create `test/llmagent/os_process_test.exs`:

```elixir
defmodule LLMAgent.OSProcessTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias LLMAgent.OSProcess

  # A killed child stays in /proc as a zombie until reaped, so existence alone
  # is not liveness — read the state field out of stat.
  defp spawn_sleeper do
    port = Port.open({:spawn_executable, System.find_executable("sleep")},
                     [:binary, :exit_status, {:args, ["300"]}])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {port, os_pid}
  end

  test "alive?/1 is true for a running process" do
    {port, os_pid} = spawn_sleeper()
    assert OSProcess.alive?(os_pid)
    OSProcess.reap(os_pid)
    Port.close(port)
  end

  test "alive?/1 is false for a pid that does not exist" do
    refute OSProcess.alive?(2_147_483_646)
  end

  test "reap/1 kills a running process" do
    {port, os_pid} = spawn_sleeper()
    assert :ok = OSProcess.reap(os_pid)
    refute OSProcess.alive?(os_pid)
    Port.close(port)
  end

  test "reap/1 accepts nil" do
    assert :ok = OSProcess.reap(nil)
  end

  test "reap/1 is safe to call twice" do
    {port, os_pid} = spawn_sleeper()
    assert :ok = OSProcess.reap(os_pid)
    assert :ok = OSProcess.reap(os_pid)
    Port.close(port)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/llmagent/os_process_test.exs </dev/null`

Expected: FAIL — `LLMAgent.OSProcess.alive?/1 is undefined (module LLMAgent.OSProcess is not available)`.

Note: always redirect stdin from `/dev/null` when running `mix` in this repo. A leaked discovery shim can otherwise hold the inherited stdout pipe open and the command appears to hang.

- [ ] **Step 3: Write minimal implementation**

Create `lib/llmagent/os_process.ex`:

```elixir
defmodule LLMAgent.OSProcess do
  @moduledoc """
  Signalling for OS processes spawned as Erlang ports.

  `Port.close/1` closes the pipes; it does not signal the program. A child that
  does not exit on stdin EOF therefore survives its owner, keeps running, and
  keeps holding the stdout it inherited — which hangs whatever is reading that
  pipe. Both `LLMAgent.Discovery.PortAdapter` and `LLMAgent.Tool.Adapter.Exec`
  need the same escalating kill, so it lives here once.
  """

  @default_grace_ms 200

  @doc "True when the process exists and is not a zombie."
  @spec alive?(non_neg_integer()) :: boolean()
  def alive?(os_pid) when is_integer(os_pid) do
    {_, status} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    status == 0
  rescue
    ErlangError -> false
  end

  @doc """
  Terminate a process: SIGTERM, a grace period, then SIGKILL if it is still up.

  Accepts `nil` so callers need not special-case a port that never opened.
  """
  @spec reap(non_neg_integer() | nil, non_neg_integer()) :: :ok
  def reap(os_pid, grace_ms \\ @default_grace_ms)

  def reap(nil, _grace_ms), do: :ok

  def reap(os_pid, grace_ms) when is_integer(os_pid) do
    signal(os_pid, "-TERM")
    Process.sleep(grace_ms)

    if alive?(os_pid) do
      signal(os_pid, "-KILL")
    end

    :ok
  end

  defp signal(os_pid, sig) do
    System.cmd("kill", [sig, Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    # `kill` missing from PATH is not worth taking a shutdown down for.
    ErlangError -> :ok
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/llmagent/os_process_test.exs </dev/null`

Expected: PASS, 5 tests.

- [ ] **Step 5: Point `PortAdapter` at the new module**

In `lib/llmagent/discovery/port_adapter.ex`, delete the private `reap/1`, `signal/2` and `os_alive?/1` functions and the `@term_grace_ms` attribute. Replace the call in `terminate/2`:

```elixir
  @impl true
  def terminate(_reason, %{port: port, os_pid: os_pid}) do
    if is_port(port) and Port.info(port) != nil do
      Port.close(port)
    end

    LLMAgent.OSProcess.reap(os_pid)
    :ok
  end
```

Keep the explanatory comment above `terminate/2` describing why closing the port is not enough.

- [ ] **Step 6: Run the discovery tests to verify no regression**

Run: `mix test test/llmagent/discovery/ </dev/null`

Expected: PASS, 13 tests. The existing test `"kills the shim's OS process when the adapter terminates"` must still pass — it is the regression guard for this refactor.

- [ ] **Step 7: Commit**

```bash
git add lib/llmagent/os_process.ex test/llmagent/os_process_test.exs lib/llmagent/discovery/port_adapter.ex
git commit -m "Extract OS process reaping into LLMAgent.OSProcess"
```

---

### Task 2: Pass the resolved ad to adapters via `opts`

Adapter callbacks receive the binding payload and `opts`, never the ad. The exec guards need `ad.constraint.blast_radius` and `ad.meta.extraction`.

**Files:**

- Modify: `lib/llmagent/tool/dispatcher.ex` (the `dispatch/5` private function)
- Create: `test/llmagent/tool/adapter_opts_test.exs`

**Interfaces:**

- Consumes: nothing from Task 1.
- Produces: every adapter callback now receives `opts` containing `{:ad, %LLMAgent.ToolAd{}}`. Later tasks read it with `Keyword.fetch!(opts, :ad)`.

- [ ] **Step 1: Write the failing test**

Create `test/llmagent/tool/adapter_opts_test.exs`:

```elixir
defmodule LLMAgent.Tool.AdapterOptsTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias LLMAgent.{ToolAd, Tool.Bindings, Tool.Dispatcher, Tool.Policy}

  # Records the opts it was handed so the test can assert on them.
  defmodule Spy do
    @behaviour LLMAgent.Tool.Adapter

    @impl true
    def query(_payload, _action, _args, opts) do
      {:ok, Keyword.get(opts, :ad), %{}}
    end
  end

  setup do
    :ok = Bindings.register(:spy, Spy)
    on_exit(fn -> Bindings.unregister(:spy) end)
    :ok
  end

  defp spy_ad do
    ToolAd.new(%{
      id: "spy.1",
      coordinate: "function.spy",
      kinds: [:query],
      binding: {:spy, %{}},
      operational: %{actions: %{}},
      constraint: %{idempotency: %{}, blast_radius: %{}},
      affordance: %{declared: [], learned: [], open: false},
      fidelity: :authoritative,
      provenance: %{source: "test", produced_at: ~U[2026-08-05 00:00:00Z], based_on: [], signature: nil},
      lease: :permanent
    })
  end

  test "the adapter receives the resolved ad in opts" do
    ad = spy_ad()
    policy = %Policy{allow: ["function.spy"], fidelity_min: :speculative}

    assert {:ok, %ToolAd{} = seen, _meta} =
             Dispatcher.query(ad, "anything", %{}, policy: policy)

    assert seen.id == "spy.1"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/llmagent/tool/adapter_opts_test.exs </dev/null`

Expected: FAIL — the assertion `{:ok, %ToolAd{} = seen, _meta}` does not match because the adapter returns `{:ok, nil, %{}}`.

- [ ] **Step 3: Write minimal implementation**

In `lib/llmagent/tool/dispatcher.ex`, inside `dispatch/5`, add the ad to `opts` immediately before `invoke/6` is called:

```elixir
         {:ok, adapter, payload} <- resolve_adapter(ad) do
      # Adapters that need ad context — the :exec guards read blast_radius and
      # meta.extraction — get it here rather than having it duplicated into
      # every binding payload.
      opts = Keyword.put(opts, :ad, ad)
      result = invoke(adapter, kind, payload, action_or_role_or_spec, args, opts)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/llmagent/tool/adapter_opts_test.exs </dev/null`

Expected: PASS, 1 test.

- [ ] **Step 5: Run the full suite to check the shared dispatch path**

Run: `mix test </dev/null`

Expected: 412 tests with exactly 4 failures, all in `LLMAgent.Tools.WebTest`. Those 4 hit the live `httpbin.org` and are a known pre-existing defect recorded in `ISSUES.md`. Any *other* failure is a regression from this change — most likely in a tool whose `participate/3` or `spawn_child/2` now receives the extra `:ad` key, since `Adapter.Module` forwards `opts` verbatim. Fix before continuing.

- [ ] **Step 6: Commit**

```bash
git add lib/llmagent/tool/dispatcher.ex test/llmagent/tool/adapter_opts_test.exs
git commit -m "Pass the resolved ad to binding adapters via opts"
```

---

### Task 3: `Adapter.Exec` — argv execution and exit status

Execution mechanics only. Guards arrive in Task 5.

**Files:**

- Create: `lib/llmagent/tool/adapter/exec.ex`
- Create: `test/llmagent/tool/adapter/exec_test.exs`

**Interfaces:**

- Consumes: `LLMAgent.OSProcess` from Task 1 (not yet used until Task 4); `opts[:ad]` from Task 2.
- Produces: `LLMAgent.Tool.Adapter.Exec.act(payload :: map(), action :: String.t(), args :: map(), idempotency_key :: term(), opts :: keyword())` returning `{:ok, output :: binary(), meta :: map()}` or `{:error, term()}`. `payload` is `%{argv: [path | _], interpreter: binary()}`. `args` is `%{"args" => [binary()]}`; a missing `"args"` key means no arguments.

- [ ] **Step 1: Write the failing test**

Create `test/llmagent/tool/adapter/exec_test.exs`:

```elixir
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

  test "an unknown action is refused", %{dir: dir} do
    path = fixture(dir, "hello.sh", "#!/bin/bash\necho hello\n")
    payload = %{argv: [path], interpreter: "bash"}
    assert {:error, {:unknown_action, "frobnicate"}} =
             Exec.act(payload, "frobnicate", %{}, nil, ad: ad_for(path))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/llmagent/tool/adapter/exec_test.exs </dev/null`

Expected: FAIL — `LLMAgent.Tool.Adapter.Exec.act/5 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/llmagent/tool/adapter/exec.ex`:

```elixir
defmodule LLMAgent.Tool.Adapter.Exec do
  @moduledoc """
  Adapter for `:exec` bindings — local executables discovered by
  `priv/discovery/bin-watch.tcl`.

  The binding payload is `%{argv: [path], interpreter: name}`. Caller arguments
  are appended to argv as separate entries and the program is spawned directly.
  **No shell is involved at any point**, so `;`, `|`, backticks and `$(...)`
  arrive as ordinary argument text.

  That matters more here than in most adapters. Of the comma-tools this shim
  watches, many have no argument parsing at all — they read `$1` positionally,
  so `,mkbooter --help` does not print help, it runs `dd | sudo dd`. Every ad is
  `:fidelity :speculative`, derived from reading source and never from running
  anything. There is no safe way to probe these tools, which is why the guards
  in `act/5` refuse rather than experiment.

  See `docs/superpowers/specs/2026-08-05-exec-binding-adapter-design.md`.
  """

  @behaviour LLMAgent.Tool.Adapter

  @default_timeout 30_000
  @output_cap 262_144

  @impl true
  @doc "Run the bound executable. The only supported action is `\"run\"`."
  def act(_payload, action, _args, _key, _opts) when action != "run" do
    {:error, {:unknown_action, action}}
  end

  # `idempotency_key` is accepted and ignored: these commands have no
  # idempotency mechanism, and honouring the parameter would be a claim this
  # adapter cannot keep.
  def act(payload, "run", args, _idempotency_key, opts) do
    ad = Keyword.fetch!(opts, :ad)
    argv = Map.get(args, "args", [])

    {exe, full_argv} = resolve_exe(payload, ad, argv)
    run(exe, full_argv, opts)
  end

  # A file with no shebang cannot be exec'd by the kernel. Running it as an
  # argument to sh is still an argv exec, not a shell command string.
  defp resolve_exe(payload, ad, argv) do
    path = payload |> Map.fetch!(:argv) |> List.first()

    if Map.get(ad.meta || %{}, :no_shebang) do
      {System.find_executable("sh"), [path | argv]}
    else
      {path, argv}
    end
  end

  defp run(exe, argv, opts) do
    started = System.monotonic_time(:millisecond)

    port_opts =
      [:binary, :exit_status, :stderr_to_stdout, {:args, argv}] ++
        cd_opt(opts) ++ env_opt(opts)

    port = Port.open({:spawn_executable, exe}, port_opts)

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, p} -> p
        nil -> nil
      end

    collect(port, os_pid, timeout(opts), [], 0, started)
  rescue
    e in [ErlangError, ArgumentError] -> {:error, {:spawn_failed, e}}
  end

  defp collect(port, os_pid, timeout, acc, size, started) do
    receive do
      {^port, {:data, chunk}} ->
        {acc, size} = accumulate(acc, size, chunk)
        collect(port, os_pid, timeout, acc, size, started)

      {^port, {:exit_status, status}} ->
        output = finish(acc)
        meta = %{
          status: status,
          truncated: size > @output_cap,
          duration_ms: System.monotonic_time(:millisecond) - started
        }

        if status == 0 do
          {:ok, output, meta}
        else
          {:error, {:exit_status, status, output}}
        end
    after
      timeout ->
        LLMAgent.OSProcess.reap(os_pid)
        safe_close(port)
        {:error, {:timeout, timeout, finish(acc)}}
    end
  end

  # Stop accumulating once the cap is passed; keep counting so `truncated` is
  # accurate.
  defp accumulate(acc, size, chunk) do
    if size >= @output_cap do
      {acc, size + byte_size(chunk)}
    else
      {[chunk | acc], size + byte_size(chunk)}
    end
  end

  defp finish(acc) do
    acc |> Enum.reverse() |> IO.iodata_to_binary() |> binary_part_capped()
  end

  defp binary_part_capped(bin) when byte_size(bin) <= @output_cap, do: bin
  defp binary_part_capped(bin), do: binary_part(bin, 0, @output_cap)

  defp safe_close(port) do
    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp timeout(opts), do: Keyword.get(opts, :exec_timeout, @default_timeout)

  defp cd_opt(opts) do
    case Keyword.get(opts, :exec_cd) do
      nil -> []
      dir -> [{:cd, dir}]
    end
  end

  defp env_opt(opts) do
    case Keyword.get(opts, :exec_env) do
      nil -> []
      env -> [{:env, env}]
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/llmagent/tool/adapter/exec_test.exs </dev/null`

Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/tool/adapter/exec.ex test/llmagent/tool/adapter/exec_test.exs
git commit -m "Add :exec binding adapter with argv-only execution"
```

---

### Task 4: Timeout and output truncation

**Files:**

- Modify: `test/llmagent/tool/adapter/exec_test.exs` (add tests)
- Modify: `lib/llmagent/tool/adapter/exec.ex` only if the tests reveal a defect — the timeout and cap logic was written in Task 3 but is not yet exercised.

**Interfaces:**

- Consumes: `Exec.act/5` from Task 3, `LLMAgent.OSProcess.alive?/1` from Task 1.
- Produces: no new public functions.

- [ ] **Step 1: Write the failing test**

Append to `test/llmagent/tool/adapter/exec_test.exs`, inside the module:

```elixir
  # Reads the state field out of /proc rather than testing existence, because a
  # killed child stays in /proc as a zombie until the VM reaps it.
  defp os_alive?(os_pid) do
    case File.read("/proc/#{os_pid}/stat") do
      {:ok, stat} -> stat |> String.split(") ") |> List.last() |> String.first() != "Z"
      {:error, _} -> false
    end
  end

  test "a command that overruns its timeout is killed", %{dir: dir} do
    path = fixture(dir, "slow.sh", "#!/bin/bash\necho $$ > #{dir}/pidfile\nsleep 60\n")

    assert {:error, {:timeout, 400, _partial}} =
             call(path, %{}, exec_timeout: 400)

    # The shim wrote its own pid before sleeping; it must be gone now.
    os_pid = dir |> Path.join("pidfile") |> File.read!() |> String.trim() |> String.to_integer()
    refute os_alive?(os_pid)
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
```

- [ ] **Step 2: Run tests to verify they pass or reveal a defect**

Run: `mix test test/llmagent/tool/adapter/exec_test.exs </dev/null`

Expected: PASS, 11 tests. These exercise code written in Task 3, so they may pass immediately — that is a valid outcome for this task, not a reason to skip it. If any fail, fix `exec.ex` before continuing. The most likely defect is the timeout path failing to kill the process, in which case check that `os_pid` was captured before the port closed.

- [ ] **Step 3: Commit**

```bash
git add test/llmagent/tool/adapter/exec_test.exs lib/llmagent/tool/adapter/exec.ex
git commit -m "Cover exec timeout kill and output truncation"
```

---

### Task 5: Refusal guards

**Files:**

- Modify: `lib/llmagent/tool/adapter/exec.ex`
- Modify: `test/llmagent/tool/adapter/exec_test.exs`

**Interfaces:**

- Consumes: `opts[:ad]` from Task 2.
- Produces: `act/5` gains four refusal paths returning `{:error, {:arity_mismatch, [expected: n, got: m]}}`, `{:error, {:refused, :blast_radius, scope}}` and `{:error, {:refused, :extraction, value}}`. Lifted by `exec_allow_blast_radius: [atom()]` and `exec_allow_extraction: [atom()]`.

- [ ] **Step 1: Write the failing test**

Append to `test/llmagent/tool/adapter/exec_test.exs`, inside the module:

```elixir
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
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/llmagent/tool/adapter/exec_test.exs </dev/null`

Expected: FAIL — the guard tests all execute the fixture and return `{:ok, ...}` because no guards exist yet.

- [ ] **Step 3: Write the implementation**

In `lib/llmagent/tool/adapter/exec.ex`, replace the `act(payload, "run", ...)` clause with a guarded version and add the guard helpers:

```elixir
  def act(payload, "run", args, _idempotency_key, opts) do
    ad = Keyword.fetch!(opts, :ad)
    argv = Map.get(args, "args", [])

    with :ok <- check_arity(ad, argv),
         :ok <- check_blast_radius(ad, opts),
         :ok <- check_extraction(ad, opts) do
      {exe, full_argv} = resolve_exe(payload, ad, argv)
      run(exe, full_argv, opts)
    end
  end

  # Arity comes from the ad's own action spec. For a variadic tool it is a
  # minimum; otherwise it is exact.
  defp check_arity(ad, argv) do
    spec = ad.operational |> Map.get(:actions, %{}) |> Map.get("run", %{})
    arity = Map.get(spec, :arity, 0)
    variadic = Map.get(spec, :variadic, false)
    got = length(argv)

    cond do
      variadic and got < arity -> {:error, {:arity_mismatch, [expected: arity, got: got]}}
      not variadic and got != arity -> {:error, {:arity_mismatch, [expected: arity, got: got]}}
      true -> :ok
    end
  end

  # A tool that can reach the whole system, or whose reach could not be
  # determined, is refused. `constraint` may legitimately be a `{:ref, coord}`
  # tuple rather than a map; that is not a readable signal, so it refuses too.
  defp check_blast_radius(ad, opts) do
    scope =
      case ad.constraint do
        %{blast_radius: %{scope: scope}} -> scope
        _ -> :unknown
      end

    allowed = Keyword.get(opts, :exec_allow_blast_radius, [])

    if scope in [:system, :unknown] and scope not in allowed do
      {:error, {:refused, :blast_radius, scope}}
    else
      :ok
    end
  end

  # `:incomplete` and `:unsupported` both mean the ad's `:requires` list is
  # known to be short — the tool touches more than the ad admits. A missing
  # signal is treated the same way; absence of evidence is not permission.
  defp check_extraction(ad, opts) do
    extraction = Map.get(ad.meta || %{}, :extraction, :unknown)
    allowed = Keyword.get(opts, :exec_allow_extraction, [])

    if extraction in [:incomplete, :unsupported, :unknown] and extraction not in allowed do
      {:error, {:refused, :extraction, extraction}}
    else
      :ok
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/llmagent/tool/adapter/exec_test.exs </dev/null`

Expected: PASS, 20 tests.

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/tool/adapter/exec.ex test/llmagent/tool/adapter/exec_test.exs
git commit -m "Refuse exec calls on blast radius, extraction and arity"
```

---

### Task 6: Register the binding and make the shim declare `:action`

**Files:**

- Modify: `lib/llmagent/tool/bindings.ex` (the `@canonical` map)
- Modify: `priv/discovery/bin-watch.tcl` (`kinds_for`)
- Modify: `test/tcl/bin_watch_test.tcl`
- Create: `test/llmagent/tool/adapter/exec_dispatch_test.exs`

**Interfaces:**

- Consumes: everything from Tasks 1–5.
- Produces: `Bindings.adapter_for(:exec)` returns `{:ok, LLMAgent.Tool.Adapter.Exec}`.

- [ ] **Step 1: Write the failing end-to-end test**

Create `test/llmagent/tool/adapter/exec_dispatch_test.exs`:

```elixir
defmodule LLMAgent.Tool.Adapter.ExecDispatchTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias LLMAgent.{ToolAd, Tool.Bindings, Tool.Dispatcher, Tool.Policy}

  setup do
    dir = Path.join(System.tmp_dir!(), "exec_dispatch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp fixture(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end

  defp ad_for(path) do
    ToolAd.new(%{
      id: "bin:#{path}",
      coordinate: "command.local.dispatchfixture",
      kinds: [:action],
      binding: {:exec, %{argv: [path], interpreter: "bash"}},
      operational: %{actions: %{"run" => %{arity: 0, variadic: true}}},
      constraint: %{idempotency: %{}, blast_radius: %{scope: :none}},
      affordance: %{declared: [], learned: [], open: true},
      fidelity: :speculative,
      provenance: %{source: "test", produced_at: ~U[2026-08-05 00:00:00Z], based_on: [], signature: nil},
      lease: :permanent,
      meta: %{extraction: :complete, language: "bash"}
    })
  end

  test ":exec resolves to the Exec adapter" do
    assert {:ok, LLMAgent.Tool.Adapter.Exec} = Bindings.adapter_for(:exec)
  end

  test "a discovered command runs end to end through the dispatcher", %{dir: dir} do
    path = fixture(dir, "greet.sh", "#!/bin/bash\necho \"hi $1\"\n")
    ad = ad_for(path)

    policy = %Policy{
      allow: ["command.local.*"],
      fidelity_min: :speculative
    }

    assert {:ok, output, meta} =
             Dispatcher.act(ad, "run", %{"args" => ["there"]}, policy: policy)

    assert output =~ "hi there"
    assert meta.status == 0
  end

  # The default policy denies everything and requires :trained fidelity; these
  # ads are :speculative. Discovery alone must not make a tool callable.
  test "the default policy refuses a discovered command", %{dir: dir} do
    path = fixture(dir, "greet.sh", "#!/bin/bash\necho hi\n")

    assert {:error, :forbidden, _reason} =
             Dispatcher.act(ad_for(path), "run", %{}, policy: %Policy{})
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/llmagent/tool/adapter/exec_dispatch_test.exs </dev/null`

Expected: FAIL — `adapter_for(:exec)` returns `{:error, :not_found}`.

- [ ] **Step 3: Register the adapter**

In `lib/llmagent/tool/bindings.ex`, add `:exec` to `@canonical`:

```elixir
  @canonical %{
    module: LLMAgent.Tool.Adapter.Module,
    openai_chat: LLMAgent.Tool.Adapter.OpenAIChat,
    exec: LLMAgent.Tool.Adapter.Exec
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/llmagent/tool/adapter/exec_dispatch_test.exs </dev/null`

Expected: PASS, 3 tests.

- [ ] **Step 5: Write the failing Tcl test for the kind change**

In `test/tcl/bin_watch_test.tcl`, add before `cleanupTests`:

```tcl
# Running a binary is I/O, and "this tool has no side effects" is an inference
# from reading source, not a fact. Declaring :query would put a purity label on
# a guess. The read-only distinction survives in :blast_radius instead.
test kinds-always-action {every ad declares :action, never :query} -body {
    set harmless [facts_for harmless.sh "#!/bin/bash\npdfinfo \"\$1\"\n"]
    set risky    [facts_for risky.sh "#!/bin/bash\nrm -rf \"\$1\"\n"]
    list [kinds_for $harmless] [kinds_for $risky]
} -result {action action}

test blast-radius-still-distinguishes {the read-only signal survives in blast_radius} -body {
    set harmless [facts_for harmless2.sh "#!/bin/bash\npdfinfo \"\$1\"\n"]
    string match "*:scope :none*" [blast_radius $harmless]
} -result 1
```

- [ ] **Step 6: Run the Tcl test to verify it fails**

Run: `tclsh test/tcl/bin_watch_test.tcl`

Expected: FAIL on `kinds-always-action` — the harmless fixture currently yields `query`.

- [ ] **Step 7: Change `kinds_for`**

In `priv/discovery/bin-watch.tcl`, replace `kinds_for`:

```tcl
# Every ad declares :action, never :query.
#
# LLMAgent.Tool.Adapter documents :query as "pure, idempotent, no side effects".
# Running a binary is I/O, and the claim that a particular binary is harmless is
# an inference drawn from reading its source — exactly the sort of unverified
# assertion :fidelity exists to flag. Labelling a guess as purity inverts that.
#
# The distinction is not lost: it lives in :blast_radius, where it is honestly
# presented as an inference. A consumer wanting harmless tools filters on
# {:scope :none} rather than trusting a purity claim.
proc kinds_for {facts} {
    return {action}
}
```

- [ ] **Step 8: Run the Tcl suite**

Run: `make test-tcl`

Expected: PASS, 20 tests.

- [ ] **Step 9: Verify against the real tool population**

Run: `tclsh priv/discovery/bin-watch.tcl --once | grep -c ':kinds \[:action\]'`

Expected: `32` — every ad now declares `:action`.

Run: `tclsh priv/discovery/bin-watch.tcl --once | grep -o ':missing \[[^]]*\]' | grep -v ':missing \[\]'`

Expected: exactly three lines, for `yt`, `metaflac` and `dns-sd`. Any other token is a regression in the extractor.

- [ ] **Step 10: Run the full suite**

Run: `mix test </dev/null && make test-tcl`

Expected: 412+ ExUnit tests with only the 4 known `LLMAgent.Tools.WebTest` failures, and 20 Tcl tests passing.

- [ ] **Step 11: Commit**

```bash
git add lib/llmagent/tool/bindings.ex priv/discovery/bin-watch.tcl \
        test/tcl/bin_watch_test.tcl test/llmagent/tool/adapter/exec_dispatch_test.exs
git commit -m "Register the :exec binding and declare discovered commands as actions"
```

---

### Task 7: Documentation

**Files:**

- Modify: `README.md`
- Modify: `ISSUES.md`

**Interfaces:**

- Consumes: everything above.
- Produces: nothing code-facing.

- [ ] **Step 1: Update the README**

The README's ASCII diagram says "10 Tools" while `Builtins.register_all/0` registers 12, and its supervision tree omits `LLMAgent.Tools.Discovery` and `LLMAgent.Discovery.AdapterSupervisor`. Both are recorded as defects in `ISSUES.md` under "Documentation drift". Fix those two counts while adding a short section describing the `:exec` binding:

- The binding kind and its payload shape.
- That execution is argv-only and never uses a shell.
- That guards refuse `:system`/`:unknown` blast radius and incomplete extraction, and that `Policy` still runs first and denies by default.

- [ ] **Step 2: Close the resolved item in `ISSUES.md`**

The entry "mDNS-discovered endpoints are write-only when `llmagent` runs standalone" says discovery is a service llmagent provides but never consumes. That is now partly false: discovered `command.local.*` ads are consumable through `Dispatcher.act/4`. Add a resolution note recording what changed and what has not — there is still no `:generate` dispatch branch for the mDNS `compute.llm.chat` ads, so the original complaint stands for those.

- [ ] **Step 3: Commit**

```bash
git add README.md ISSUES.md
git commit -m "Document the :exec binding and fix README tool counts"
```

---

## Self-review notes

Spec coverage check against `2026-08-05-exec-binding-adapter-design.md`:

| Spec section | Task |
| --- | --- |
| D1 positional args | 3 (pass-through), 5 (arity check) |
| D2 refusal on ad signals | 5 |
| D3 dispatcher passes ad | 2 |
| D4 `act/5` only, shim declares `:action` | 3 (no `query/4` defined), 6 |
| Interface / return shapes | 3, 5 |
| Guard order | 5 (including the ordering test) |
| No shell | 3 (metacharacter test) |
| No-shebang handling | 3 |
| Timeout, TERM/KILL | 1, 4 |
| Output cap | 4 |
| Env and cwd | 3 (`exec_cd`, `exec_env`) |
| Idempotency ignored | 3 (documented in moduledoc) |
| `OSProcess` extraction | 1 |
| Registration in `Bindings` | 6 |
| Testing list | 3, 4, 5, 6 |
| Risk: shared dispatch path | 2 (full-suite step) |
| Risk: absent fields refuse | 5 |

No spec requirement is unassigned. `:confidence` and `query/4` are explicitly out of scope in the spec and have no tasks, which is correct.

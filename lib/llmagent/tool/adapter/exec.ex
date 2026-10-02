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

  ## Idempotency

  `act/5` accepts `idempotency_key` and ignores it. These commands have no
  idempotency mechanism, and honouring the parameter would be a claim this
  adapter cannot keep. It is documented here rather than silently dropped.

  ## Process ownership

  The port is opened inside a process this module spawns, never in the caller's
  process. Two properties follow, and both matter because timeouts are the
  expected outcome for a large part of this tool population:

    * The dying child's final `{port, {:data, _}}` and `{port, {:exit_status,
      _}}` messages land in the runner's mailbox and die with it. A GenServer
      caller — `LLMAgent` has no catch-all `handle_info/2` — never sees stray
      port mail after a timeout.
    * The runner monitors its caller. If the caller dies while output
      collection is blocked, the runner reaps the OS process rather than
      leaving it running and holding the stdout it inherited.

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

  # `idempotency_key` is accepted and ignored — see the moduledoc.
  def act(payload, "run", args, _idempotency_key, opts) do
    ad = Keyword.fetch!(opts, :ad)
    argv = Map.get(args, "args", [])

    with :ok <- check_arity(ad, argv),
         :ok <- check_blast_radius(ad, opts),
         :ok <- check_extraction(ad, opts),
         {:ok, exe, full_argv} <- resolve_exe(payload, ad, argv) do
      run(exe, full_argv, opts)
    end
  end

  # Arity comes from the ad's own action spec. For a variadic tool it is a
  # minimum; otherwise it is exact. A missing or malformed spec — no
  # `:actions` key, no `"run"` entry, a non-integer arity, a non-boolean
  # variadic flag — is not "this tool takes no arguments", it is "we do not
  # know what this tool takes", and a zero-argument call is exactly how an
  # unparsed positional tool like `,update` would be invoked. That absent
  # signal refuses rather than defaulting to permission. Non-list `argv`
  # (a malformed `args["args"]`) refuses instead of raising in `length/1`.
  defp check_arity(ad, argv) when is_list(argv) do
    with %{actions: %{"run" => %{arity: arity, variadic: variadic}}} <- ad.operational,
         true <- is_integer(arity) and arity >= 0 and is_boolean(variadic) do
      got = length(argv)

      cond do
        variadic and got < arity -> {:error, {:arity_mismatch, [expected: arity, got: got]}}
        not variadic and got != arity -> {:error, {:arity_mismatch, [expected: arity, got: got]}}
        true -> :ok
      end
    else
      _ -> {:error, {:refused, :arity, :unknown}}
    end
  end

  defp check_arity(_ad, _argv), do: {:error, {:refused, :arity, :unknown}}

  # Allowlist, not denylist: only a scope the shim's vocabulary declares safe
  # (`:none`, `:filesystem`) proceeds. Everything else — `:system`, an
  # out-of-vocabulary atom like `:host`, a non-atom value, a missing
  # `blast_radius` key, or a `{:ref, coord}` constraint (which never matches
  # the map pattern below and falls to the catch-all) — refuses. An `:exec`
  # binding's `constraint` is not guaranteed to come from this shim's closed
  # vocabulary, so the guard's contract can't rely on that being the only
  # source of ads.
  defp check_blast_radius(ad, opts) do
    scope =
      case ad.constraint do
        %{blast_radius: %{scope: scope}} -> scope
        _ -> :unknown
      end

    allowed = Keyword.get(opts, :exec_allow_blast_radius, [])

    if scope in [:none, :filesystem] or scope in allowed do
      :ok
    else
      {:error, {:refused, :blast_radius, normalise_signal(scope)}}
    end
  end

  # Allowlist, not denylist: only `:complete` extraction proceeds. `nil` or a
  # non-map `meta` (including a `{:ref, coord}` tuple) is read the same way
  # `check_blast_radius/2` reads `constraint` — the `case` catch-all, not a
  # `|| %{}` fallback, so a truthy non-map value can't raise BadMapError.
  # `:incomplete`, `:unsupported`, any other atom, and a missing signal all
  # refuse; absence of evidence is not permission.
  defp check_extraction(ad, opts) do
    extraction =
      case ad.meta do
        %{extraction: extraction} -> extraction
        _ -> :unknown
      end

    allowed = Keyword.get(opts, :exec_allow_extraction, [])

    if extraction == :complete or extraction in allowed do
      :ok
    else
      {:error, {:refused, :extraction, normalise_signal(extraction)}}
    end
  end

  # The reported value in a refusal tuple is always an atom, even when the
  # observed signal was not — a stray string or other foreign type collapses
  # to `:unknown` rather than leaking an arbitrary term into the error shape.
  defp normalise_signal(value) when is_atom(value), do: value
  defp normalise_signal(_value), do: :unknown

  # The *whole* argv from the binding is the command prefix; caller arguments
  # are appended after it. Keeping only the head would turn an ordinary
  # `argv: ["/usr/bin/env", "myscript"]` ad into "run /usr/bin/env with
  # model-controlled arguments" — arbitrary execution wearing one script's
  # coordinate.
  #
  # A file with no shebang cannot be exec'd by the kernel. Running it as an
  # argument to sh is still an argv exec, not a shell command string; `--`
  # stops sh reading a path that begins with `-` as an option, which is the
  # only route to a shell anywhere in this module.
  #
  # A payload without a binary argv head refuses, like every other malformed
  # input here, rather than raising out through the dispatcher.
  defp resolve_exe(%{argv: [path | rest]}, ad, argv) when is_binary(path) do
    prefix = rest ++ argv

    if no_shebang?(ad) do
      {:ok, System.find_executable("sh"), ["--", path | prefix]}
    else
      {:ok, path, prefix}
    end
  end

  defp resolve_exe(_payload, _ad, _argv), do: {:error, {:refused, :binding, :malformed}}

  # Allowlist, same shape as `check_extraction/2`: only a literal `true` in a
  # map `meta` selects the sh path. A `nil`, a non-map `meta` (a `{:ref, coord}`
  # tuple) and any other value read as "no".
  defp no_shebang?(%{meta: %{no_shebang: true}}), do: true
  defp no_shebang?(_ad), do: false

  # The port is opened in a process this module spawns, not in the caller's.
  # See the moduledoc: stray port mail after a timeout dies with the runner
  # instead of reaching a GenServer with no catch-all `handle_info/2`, and a
  # caller that dies mid-collection still gets its OS process reaped.
  #
  # The runner bounds its own runtime (the collect deadline plus the reap
  # grace) and reports the timeout itself, so the caller waits without a
  # competing timeout of its own.
  defp run(exe, argv, opts) do
    caller = self()

    port_opts =
      [:binary, :exit_status, :stderr_to_stdout, {:args, argv}] ++
        cd_opt(opts) ++ env_opt(opts)

    total_timeout = timeout(opts)

    {runner, mon} =
      spawn_monitor(fn ->
        caller_ref = Process.monitor(caller)
        send(caller, {:exec_result, self(), owned_run(exe, port_opts, total_timeout, caller_ref)})
      end)

    receive do
      {:exec_result, ^runner, result} ->
        Process.demonitor(mon, [:flush])
        result

      {:DOWN, ^mon, :process, ^runner, reason} ->
        {:error, {:runner_exited, reason}}
    end
  end

  defp owned_run(exe, port_opts, total_timeout, caller_ref) do
    started = System.monotonic_time(:millisecond)

    case open_port(exe, port_opts) do
      {:ok, port} ->
        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, p} -> p
            nil -> nil
          end

        collect(port, os_pid, total_timeout, started + total_timeout, [], 0, started, caller_ref)

      {:error, _} = err ->
        err
    end
  end

  # Narrow: only the spawn itself. A rescue spanning collection would report a
  # later failure as `:spawn_failed` and leak both the port and the OS process.
  defp open_port(exe, port_opts) do
    {:ok, Port.open({:spawn_executable, exe}, port_opts)}
  rescue
    e in ErlangError -> {:error, {:spawn_failed, e}}
    e in ArgumentError -> {:error, {:spawn_failed, e}}
  end

  # `total_timeout` bounds total wall-clock runtime, not idle time between
  # chunks: `deadline` is fixed once in `run/3` and the `after` value here is
  # the *remaining* budget, so a process that emits output continuously (a
  # progress bar, `pv`, any of the "dd | pv | sudo dd" tools this module's
  # moduledoc warns about) still gets killed on schedule instead of resetting
  # the clock on every chunk.
  defp collect(port, os_pid, total_timeout, deadline, acc, size, started, caller_ref) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        {acc, size} = accumulate(acc, size, chunk)
        collect(port, os_pid, total_timeout, deadline, acc, size, started, caller_ref)

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

      # Nobody is left to receive the result. Reap rather than run to the
      # deadline holding the caller's inherited stdout.
      {:DOWN, ^caller_ref, :process, _pid, _reason} ->
        LLMAgent.OSProcess.reap(os_pid)
        safe_close(port)
        {:error, :caller_gone}
    after
      remaining ->
        LLMAgent.OSProcess.reap(os_pid)
        safe_close(port)
        {:error, {:timeout, total_timeout, finish(acc)}}
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

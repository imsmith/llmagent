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
    e in ErlangError -> {:error, {:spawn_failed, e}}
    e in ArgumentError -> {:error, {:spawn_failed, e}}
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

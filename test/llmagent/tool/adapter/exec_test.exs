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

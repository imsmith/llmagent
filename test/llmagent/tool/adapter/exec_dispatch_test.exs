defmodule LLMAgent.Tool.Adapter.ExecDispatchTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias LLMAgent.{ToolAd, ToolQuery, Tool.Bindings, Tool.Dispatcher, Tool.Policy, Tools.Discovery}

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
      provenance: %{
        source: "test",
        produced_at: ~U[2026-08-05 00:00:00Z],
        based_on: [],
        signature: nil
      },
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
             Dispatcher.act(ad, "run", %{"args" => ["there"]}, nil, policy: policy)

    assert output =~ "hi there"
    assert meta.status == 0
  end

  # The default policy denies everything and requires :trained fidelity; these
  # ads are :speculative. Discovery alone must not make a tool callable.
  test "the default policy refuses a discovered command", %{dir: dir} do
    path = fixture(dir, "greet.sh", "#!/bin/bash\necho hi\n")

    assert {:error, :forbidden, _reason} =
             Dispatcher.act(ad_for(path), "run", %{}, nil, policy: %Policy{})
  end

  # Every real caller passes a coordinate string, not a struct: the
  # Discovery.find_one/1 leg is the one the agent and the registry exercise.
  test "a discovered command runs when dispatched by coordinate string", %{dir: dir} do
    path = fixture(dir, "coord.sh", "#!/bin/bash\necho \"by coordinate $1\"\n")
    ad = ad_for(path)
    :ok = Discovery.register(ad)
    on_exit(fn -> Discovery.unregister(ad.id) end)

    assert {:ok, found} = Discovery.find_one(ToolQuery.new(%{coordinate: ad.coordinate}))
    assert found.id == ad.id

    policy = %Policy{allow: ["command.local.*"], fidelity_min: :speculative}

    assert {:ok, output, meta} =
             Dispatcher.act(ad.coordinate, "run", %{"args" => ["yes"]}, nil, policy: policy)

    assert output =~ "by coordinate yes"
    assert meta.status == 0
  end

  # `Exec` implements act/5 only. An ad declaring a kind its adapter never
  # implemented — a peer running the pre-branch shim, an ad still cached in a
  # registry, an unexpired lease — must come back as an error rather than
  # raising UndefinedFunctionError into the caller.
  test "an ad declaring a kind its adapter does not implement returns an error", %{dir: dir} do
    path = fixture(dir, "stale.sh", "#!/bin/bash\necho hi\n")
    ad = %{ad_for(path) | kinds: [:query, :action]}

    policy = %Policy{allow: ["command.local.*"], fidelity_min: :speculative}

    assert {:error, :kind_not_supported} =
             Dispatcher.query(ad, "run", %{}, policy: policy)
  end
end

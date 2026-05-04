defmodule LLMAgent.Tools.DiscoveryTest do
  @moduledoc """
  Tests for LLMAgent.Tools.Discovery GenServer.
  """

  use ExUnit.Case, async: false   # owns a named GenServer
  alias LLMAgent.{ToolAd, ToolQuery, Tools.Discovery}

  setup do
    case Process.whereis(Discovery) do
      nil -> {:ok, _pid} = Discovery.start_link([])
      _pid -> Discovery.reset!()
    end

    :ok
  end

  defp ad(overrides) do
    base = %{
      id: "test." <> Integer.to_string(System.unique_integer([:positive])),
      coordinate: "function.example",
      kinds: [:compute],
      binding: {:module, FakeMod},
      operational: %{actions: %{}},
      constraint: %{idempotency: %{}, blast_radius: %{}},
      affordance: %{declared: [], learned: [], open: false},
      fidelity: :authoritative,
      provenance: %{source: "test", produced_at: DateTime.utc_now(), based_on: [], signature: nil},
      lease: :permanent
    }

    ToolAd.new(Map.merge(base, overrides))
  end

  describe "register/1 and find_one/1" do
    test "stores and retrieves an ad by exact coordinate" do
      a = ad(%{coordinate: "function.crypto"})
      :ok = Discovery.register(a)

      assert {:ok, ^a} = Discovery.find_one(ToolQuery.new(%{coordinate: "function.crypto"}))
    end

    test "returns :not_found when no ad matches" do
      assert {:error, :not_found} =
               Discovery.find_one(ToolQuery.new(%{coordinate: "function.missing"}))
    end

    test "rejects duplicate id on register" do
      a = ad(%{id: "fixed.id"})
      :ok = Discovery.register(a)
      assert {:error, :duplicate_id} = Discovery.register(a)
    end
  end

  describe "find_all/1 — ranking" do
    test "ranks authoritative > trained > speculative" do
      auth = ad(%{id: "a1", coordinate: "function.x", fidelity: :authoritative})
      tr   = ad(%{id: "a2", coordinate: "function.x", fidelity: :trained, confidence: 0.8})
      spec = ad(%{id: "a3", coordinate: "function.x", fidelity: :speculative, confidence: 0.5})

      :ok = Discovery.register(spec)
      :ok = Discovery.register(tr)
      :ok = Discovery.register(auth)

      {:ok, [first, second, third]} =
        Discovery.find_all(ToolQuery.new(%{coordinate: "function.x"}))

      assert first.id == "a1"
      assert second.id == "a2"
      assert third.id == "a3"
    end

    test "ranks higher confidence first within fidelity" do
      lo = ad(%{id: "lo", coordinate: "function.y", fidelity: :trained, confidence: 0.3})
      hi = ad(%{id: "hi", coordinate: "function.y", fidelity: :trained, confidence: 0.9})

      :ok = Discovery.register(lo)
      :ok = Discovery.register(hi)

      {:ok, [first, _]} = Discovery.find_all(ToolQuery.new(%{coordinate: "function.y"}))
      assert first.id == "hi"
    end

    test "filters by fidelity_min" do
      auth = ad(%{id: "a", coordinate: "function.z", fidelity: :authoritative})
      tr   = ad(%{id: "t", coordinate: "function.z", fidelity: :trained, confidence: 0.5})

      :ok = Discovery.register(auth)
      :ok = Discovery.register(tr)

      {:ok, results} =
        Discovery.find_all(ToolQuery.new(%{coordinate: "function.z", fidelity_min: :authoritative}))

      assert Enum.map(results, & &1.id) == ["a"]
    end

    test "filters by required kinds" do
      query_only = ad(%{id: "qo", coordinate: "function.q", kinds: [:query]})
      both       = ad(%{id: "bb", coordinate: "function.q", kinds: [:query, :stream]})

      :ok = Discovery.register(query_only)
      :ok = Discovery.register(both)

      {:ok, results} =
        Discovery.find_all(ToolQuery.new(%{coordinate: "function.q", kinds: [:stream]}))

      assert Enum.map(results, & &1.id) == ["bb"]
    end

    test "prefix-glob matches multiple coordinates" do
      a = ad(%{id: "n1", coordinate: "resource.network.netif"})
      b = ad(%{id: "n2", coordinate: "resource.network.dns"})
      c = ad(%{id: "f1", coordinate: "resource.fs.file"})

      :ok = Discovery.register(a)
      :ok = Discovery.register(b)
      :ok = Discovery.register(c)

      {:ok, results} =
        Discovery.find_all(ToolQuery.new(%{coordinate: "resource.network.*"}))

      ids = results |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == ["n1", "n2"]
    end

    test "respects limit" do
      for i <- 1..5 do
        :ok = Discovery.register(ad(%{id: "id#{i}", coordinate: "function.bulk"}))
      end

      {:ok, results} = Discovery.find_all(ToolQuery.new(%{coordinate: "function.bulk", limit: 3}))
      assert length(results) == 3
    end
  end

  describe "update/1, unregister/1, renew/2" do
    test "update replaces the same id" do
      a = ad(%{id: "u1", coordinate: "function.u"})
      :ok = Discovery.register(a)

      a2 = %{a | meta: %{version: 2}}
      :ok = Discovery.update(a2)

      {:ok, found} = Discovery.find_one(ToolQuery.new(%{coordinate: "function.u"}))
      assert found.meta == %{version: 2}
    end

    test "unregister removes the ad" do
      a = ad(%{id: "del", coordinate: "function.d"})
      :ok = Discovery.register(a)
      :ok = Discovery.unregister("del")

      assert {:error, :not_found} =
               Discovery.find_one(ToolQuery.new(%{coordinate: "function.d"}))
    end

    test "renew updates lease only" do
      future = DateTime.add(DateTime.utc_now(), 3600)
      a = ad(%{id: "r", coordinate: "function.r", lease: {:expires_at, future}})
      :ok = Discovery.register(a)

      newer = DateTime.add(DateTime.utc_now(), 7200)
      :ok = Discovery.renew("r", newer)

      {:ok, found} = Discovery.find_one(ToolQuery.new(%{coordinate: "function.r"}))
      assert {:expires_at, ^newer} = found.lease
    end

    test "renew on unknown id returns :not_found" do
      future = DateTime.add(DateTime.utc_now(), 60)
      assert {:error, :not_found} = Discovery.renew("nope", future)
    end
  end
end

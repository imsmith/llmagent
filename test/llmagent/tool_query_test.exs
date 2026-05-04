defmodule LLMAgent.ToolQueryTest do
  @moduledoc "Tests for LLMAgent.ToolQuery struct and coordinate matcher."

  use ExUnit.Case, async: true
  alias LLMAgent.ToolQuery

  describe "new/1" do
    test "builds a query with defaults" do
      q = ToolQuery.new(%{coordinate: "resource.network.*"})
      assert q.coordinate == "resource.network.*"
      assert q.kinds == :any
      assert q.fidelity_min == :speculative
      assert q.limit == :all
    end

    test "accepts explicit kinds, fidelity_min, limit" do
      q = ToolQuery.new(%{
        coordinate: "resource.network.netif",
        kinds: [:query],
        fidelity_min: :trained,
        limit: 5
      })

      assert q.kinds == [:query]
      assert q.fidelity_min == :trained
      assert q.limit == 5
    end
  end

  describe "coordinate_matches?/2" do
    test "exact match" do
      assert ToolQuery.coordinate_matches?("resource.network.netif", "resource.network.netif")
      refute ToolQuery.coordinate_matches?("resource.network.netif", "resource.network.dns")
    end

    test "trailing-star prefix match" do
      assert ToolQuery.coordinate_matches?("resource.network.*", "resource.network.netif")
      assert ToolQuery.coordinate_matches?("resource.network.*", "resource.network.dns.cache")
      assert ToolQuery.coordinate_matches?("resource.network.*", "resource.network")
      refute ToolQuery.coordinate_matches?("resource.network.*", "resource.fs.file")
      refute ToolQuery.coordinate_matches?("resource.network.*", "resource.networking")
    end

    test "no middle-globs" do
      refute ToolQuery.coordinate_matches?("resource.*.netif", "resource.network.netif")
    end
  end
end

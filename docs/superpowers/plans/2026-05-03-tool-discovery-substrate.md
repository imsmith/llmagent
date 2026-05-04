# Tool Discovery — Substrate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the tool-discovery substrate from the spec — data structures, behaviours, registries, the `:module` adapter, Policy, Dispatcher, and the Discovery GenServer — alongside the existing `LLMAgent.Tools` registry. No tool migrations and no agent dispatch path changes; those land in follow-on plans.

**Architecture:** New modules under `LLMAgent.ToolAd`, `LLMAgent.ToolQuery`, `LLMAgent.Tool.Kinds.*`, `LLMAgent.Tool.{Adapter, Bindings, Policy, Dispatcher}`, and `LLMAgent.Tools.Discovery`. Kinds and Bindings registries are backed by `:persistent_term` (fast reads, mutations through module API). Discovery is a GenServer owning an ETS table; it absorbs `{:tool_announce, ...}` tuples from the tuple space and serves register/update/unregister/find/subscribe via direct API. Dispatcher is the single trust + observability choke point: resolve → policy check → kind check → adapter dispatch → telemetry.

**Tech Stack:** Elixir, ExUnit, ExUnit doctests, `:persistent_term`, `:ets`, `:telemetry`, existing `LLMAgent.TupleSpace` (`out`, `in_nowait`), `Comn.Errors.ErrorStruct`.

**Spec reference:** `docs/superpowers/specs/2026-05-03-tool-discovery-design.md`. Section numbers below refer to that spec.

---

## File Structure

**New (lib):**

- `lib/llmagent/tool_ad.ex` — `LLMAgent.ToolAd` struct (§1)
- `lib/llmagent/tool_query.ex` — `LLMAgent.ToolQuery` struct (§2 query record)
- `lib/llmagent/tool/kinds.ex` — `LLMAgent.Tool.Kinds` registry of kind atoms → behaviour modules (§3.8)
- `lib/llmagent/tool/kinds/query.ex` — `LLMAgent.Tool.Kinds.Query` behaviour (§3.1)
- `lib/llmagent/tool/kinds/action.ex` — `LLMAgent.Tool.Kinds.Action` behaviour (§3.2)
- `lib/llmagent/tool/kinds/stream.ex` — `LLMAgent.Tool.Kinds.Stream` behaviour (§3.3)
- `lib/llmagent/tool/kinds/compute.ex` — `LLMAgent.Tool.Kinds.Compute` behaviour (§3.4)
- `lib/llmagent/tool/kinds/coordinate.ex` — `LLMAgent.Tool.Kinds.Coordinate` behaviour (§3.5)
- `lib/llmagent/tool/kinds/spawn_kind.ex` — `LLMAgent.Tool.Kinds.SpawnKind` behaviour (§3.6) — named `SpawnKind` to avoid collision with Elixir's `Kernel.spawn/1`
- `lib/llmagent/tool/adapter.ex` — `LLMAgent.Tool.Adapter` behaviour (§4.1)
- `lib/llmagent/tool/adapter/module.ex` — `LLMAgent.Tool.Adapter.Module` adapter (§4.2)
- `lib/llmagent/tool/bindings.ex` — `LLMAgent.Tool.Bindings` registry (§4.4)
- `lib/llmagent/tool/policy.ex` — `LLMAgent.Tool.Policy` struct + decision (§6)
- `lib/llmagent/tool/dispatcher.ex` — `LLMAgent.Tool.Dispatcher` (§4.3)
- `lib/llmagent/tools/discovery.ex` — `LLMAgent.Tools.Discovery` GenServer (§2 storage, §5 register/announce/lease)

**New (test):**

- `test/llmagent/tool_ad_test.exs`
- `test/llmagent/tool_query_test.exs`
- `test/llmagent/tool/kinds_test.exs`
- `test/llmagent/tool/adapter_test.exs`
- `test/llmagent/tool/adapter/module_test.exs`
- `test/llmagent/tool/bindings_test.exs`
- `test/llmagent/tool/policy_test.exs`
- `test/llmagent/tool/dispatcher_test.exs`
- `test/llmagent/tools/discovery_test.exs`

**Modified:**

- `lib/llmagent/application.ex` — start `LLMAgent.Tools.Discovery` in the supervision tree; seed kinds and bindings registries on boot.
- `lib/tool.ex` — add `@callback ad() :: %LLMAgent.ToolAd{}` to `LLMAgent.Tool` umbrella behaviour. Mark `describe/0` and `perform/2` as `@deprecated` but keep them; add them to `@optional_callbacks`. The migration plans turn `ad/0` into a required callback for tools that have migrated.

**Unchanged in this plan:**

- `lib/tools.ex` — left as-is. Coexistence shim is a follow-on plan task (it can wait until the first tool migrates).
- All `lib/tools/*.ex` tool modules.
- `lib/LLMAgent.ex` — agent dispatch path migration is a follow-on plan.

---

## Conventions Used Across Tasks

- **Test layout.** Mirror `lib/` paths under `test/`. Use `describe/2` blocks per public function. Doctests on simple structs/modules where natural.
- **No new deps.** Everything builds on `:persistent_term`, `:ets`, `:telemetry`, and existing project deps.
- **IDs are caller-provided.** `ToolAd.id` is `@enforce_keys`. Producers pick their own (convention: `"builtin.<short_name>"` for framework-shipped ads).
- **Errors are tagged tuples** with atom or `{atom, term, term}` reasons (e.g., `{:error, :not_found}`, `{:error, {:invalid_ad, :coordinate, "empty"}}`). No `Comn.Errors.ErrorStruct` for *this* layer's own errors — that wrapper is a tool-side concern. Existing tools keep their error style; new substrate uses tagged atoms.
- **`:persistent_term` keys.** Use atoms namespaced under `:llmagent_tool_*`: `:llmagent_tool_kinds`, `:llmagent_tool_bindings`. Mutations rewrite the whole map. Reads call `:persistent_term.get(key, %{})`.
- **Coordinate matching.** Implement once, in a helper inside `LLMAgent.ToolQuery`. Other modules call `ToolQuery.coordinate_matches?(pattern, coordinate)`.
- **`SpawnKind` naming.** The `:spawn` kind's behaviour module is `LLMAgent.Tool.Kinds.SpawnKind` (atom in `kinds:` list is still `:spawn`). The qualified module name avoids `Kernel.spawn/1` shadowing in callers; the kind atom stays the natural one.

---

## Task 1: `ToolAd` struct

**Files:**
- Create: `lib/llmagent/tool_ad.ex`
- Create: `test/llmagent/tool_ad_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/llmagent/tool_ad_test.exs
defmodule LLMAgent.ToolAdTest do
  use ExUnit.Case, async: true
  alias LLMAgent.ToolAd

  describe "new/1" do
    test "builds an ad with required fields" do
      now = DateTime.utc_now()

      ad = ToolAd.new(%{
        id: "builtin.example",
        coordinate: "function.example",
        kinds: [:compute],
        binding: {:module, SomeMod},
        operational: %{actions: %{}},
        constraint: %{idempotency: %{}, blast_radius: %{}},
        affordance: %{declared: [], learned: [], open: false},
        fidelity: :authoritative,
        provenance: %{source: "test", produced_at: now, based_on: [], signature: nil},
        lease: :permanent,
        meta: %{}
      })

      assert ad.id == "builtin.example"
      assert ad.coordinate == "function.example"
      assert ad.kinds == [:compute]
      assert ad.fidelity == :authoritative
      assert ad.lease == :permanent
    end

    test "raises on missing required keys" do
      assert_raise ArgumentError, fn ->
        ToolAd.new(%{coordinate: "x"})
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/llmagent/tool_ad_test.exs`
Expected: FAIL with "module LLMAgent.ToolAd is not loaded".

- [ ] **Step 3: Implement the struct**

```elixir
# lib/llmagent/tool_ad.ex
defmodule LLMAgent.ToolAd do
  @moduledoc """
  A tool advertisement record. The single artifact in the discovery registry.

  See `docs/superpowers/specs/2026-05-03-tool-discovery-design.md` §1.
  """

  @enforce_keys [
    :id,
    :coordinate,
    :kinds,
    :binding,
    :operational,
    :constraint,
    :affordance,
    :fidelity,
    :provenance,
    :lease
  ]
  defstruct [
    :id,
    :coordinate,
    :kinds,
    :binding,
    :operational,
    :constraint,
    :affordance,
    :fidelity,
    :confidence,
    :provenance,
    :lease,
    meta: %{}
  ]

  @type binding_spec :: {atom(), term()} | nil

  @type t :: %__MODULE__{
          id: binary(),
          coordinate: String.t(),
          kinds: [atom()],
          binding: binding_spec(),
          operational: map(),
          constraint: map() | {:ref, String.t()},
          affordance: map(),
          fidelity: :authoritative | :trained | :speculative,
          confidence: float() | nil,
          provenance: map(),
          lease: :permanent | {:expires_at, DateTime.t()},
          meta: map()
        }

  @doc "Build a tool ad from a map. Raises if required fields are missing."
  @spec new(map()) :: t()
  def new(fields) when is_map(fields), do: struct!(__MODULE__, fields)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/llmagent/tool_ad_test.exs`
Expected: 2 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/tool_ad.ex test/llmagent/tool_ad_test.exs
git commit -m "Add LLMAgent.ToolAd struct"
```

---

## Task 2: `ToolQuery` struct + coordinate matching

**Files:**
- Create: `lib/llmagent/tool_query.ex`
- Create: `test/llmagent/tool_query_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/llmagent/tool_query_test.exs
defmodule LLMAgent.ToolQueryTest do
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/llmagent/tool_query_test.exs`
Expected: FAIL with "module LLMAgent.ToolQuery is not loaded".

- [ ] **Step 3: Implement the struct and matcher**

```elixir
# lib/llmagent/tool_query.ex
defmodule LLMAgent.ToolQuery do
  @moduledoc """
  Discovery query record and coordinate-matching helpers.

  See spec §2.
  """

  @enforce_keys [:coordinate]
  defstruct [
    :coordinate,
    kinds: :any,
    fidelity_min: :speculative,
    constraint: nil,
    provenance: nil,
    limit: :all
  ]

  @type t :: %__MODULE__{
          coordinate: String.t(),
          kinds: :any | [atom()],
          fidelity_min: :authoritative | :trained | :speculative,
          constraint: map() | nil,
          provenance: map() | nil,
          limit: pos_integer() | :all
        }

  @spec new(map()) :: t()
  def new(fields) when is_map(fields), do: struct!(__MODULE__, fields)

  @doc """
  Match a pattern against a coordinate.

  Pattern grammar (spec §2):
  - bare string: exact match
  - trailing `.*`: prefix match (matches the prefix itself, or prefix followed by `.<anything>`)
  - no other glob forms

  ## Examples

      iex> alias LLMAgent.ToolQuery
      iex> ToolQuery.coordinate_matches?("function.crypto.sha256", "function.crypto.sha256")
      true

      iex> alias LLMAgent.ToolQuery
      iex> ToolQuery.coordinate_matches?("resource.network.*", "resource.network.netif")
      true

      iex> alias LLMAgent.ToolQuery
      iex> ToolQuery.coordinate_matches?("resource.*.netif", "resource.network.netif")
      false
  """
  @spec coordinate_matches?(String.t(), String.t()) :: boolean()
  def coordinate_matches?(pattern, coordinate) when is_binary(pattern) and is_binary(coordinate) do
    cond do
      pattern == coordinate ->
        true

      String.ends_with?(pattern, ".*") ->
        prefix = String.trim_trailing(pattern, ".*")
        coordinate == prefix or String.starts_with?(coordinate, prefix <> ".")

      true ->
        false
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/llmagent/tool_query_test.exs`
Expected: 5 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/tool_query.ex test/llmagent/tool_query_test.exs
git commit -m "Add LLMAgent.ToolQuery struct and coordinate matcher"
```

---

## Task 3: Six kind behaviours

**Files:**
- Create: `lib/llmagent/tool/kinds/query.ex`
- Create: `lib/llmagent/tool/kinds/action.ex`
- Create: `lib/llmagent/tool/kinds/stream.ex`
- Create: `lib/llmagent/tool/kinds/compute.ex`
- Create: `lib/llmagent/tool/kinds/coordinate.ex`
- Create: `lib/llmagent/tool/kinds/spawn_kind.ex`
- Create: `test/llmagent/tool/kinds_behaviours_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/llmagent/tool/kinds_behaviours_test.exs
defmodule LLMAgent.Tool.KindsBehavioursTest do
  use ExUnit.Case, async: true

  @cases [
    {LLMAgent.Tool.Kinds.Query,       [query: 2]},
    {LLMAgent.Tool.Kinds.Action,      [act: 3]},
    {LLMAgent.Tool.Kinds.Stream,      [subscribe: 3, unsubscribe: 1]},
    {LLMAgent.Tool.Kinds.Compute,     [compute: 2]},
    {LLMAgent.Tool.Kinds.Coordinate,  [participate: 3, leave: 1]},
    {LLMAgent.Tool.Kinds.SpawnKind,   [spawn_child: 2, child_status: 1, terminate_child: 2]}
  ]

  for {mod, expected_callbacks} <- @cases do
    test "#{inspect(mod)} declares #{inspect(expected_callbacks)}" do
      callbacks = unquote(mod).behaviour_info(:callbacks)

      for {fun, arity} <- unquote(Macro.escape(expected_callbacks)) do
        assert {fun, arity} in callbacks,
               "#{unquote(inspect(mod))} missing callback #{fun}/#{arity}"
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/llmagent/tool/kinds_behaviours_test.exs`
Expected: FAIL with "module LLMAgent.Tool.Kinds.Query is not loaded" (or similar) for each.

- [ ] **Step 3: Implement the six behaviours**

```elixir
# lib/llmagent/tool/kinds/query.ex
defmodule LLMAgent.Tool.Kinds.Query do
  @moduledoc "The :query kind. Pure read; no side effects; idempotent. See spec §3.1."

  @type result :: {:ok, value :: term(), meta :: map()} | {:error, term()}

  @callback query(action :: String.t(), args :: map()) :: result()
end
```

```elixir
# lib/llmagent/tool/kinds/action.ex
defmodule LLMAgent.Tool.Kinds.Action do
  @moduledoc "The :action kind. Side effects; not retryable without idempotency. See spec §3.2."

  @type result :: {:ok, ack :: term(), meta :: map()} | {:error, term()}

  @callback act(action :: String.t(), args :: map(), idempotency_key :: String.t() | nil) ::
              result()
end
```

```elixir
# lib/llmagent/tool/kinds/stream.ex
defmodule LLMAgent.Tool.Kinds.Stream do
  @moduledoc "The :stream kind. Subscribe/unsubscribe. See spec §3.3."

  @callback subscribe(action :: String.t(), args :: map(), subscriber :: pid()) ::
              {:ok, sub_ref :: reference()} | {:error, term()}

  @callback unsubscribe(sub_ref :: reference()) :: :ok
end
```

```elixir
# lib/llmagent/tool/kinds/compute.ex
defmodule LLMAgent.Tool.Kinds.Compute do
  @moduledoc "The :compute kind. Pure transformation; no I/O. See spec §3.4."

  @callback compute(action :: String.t(), args :: map()) ::
              {:ok, value :: term()} | {:error, term()}
end
```

```elixir
# lib/llmagent/tool/kinds/coordinate.ex
defmodule LLMAgent.Tool.Kinds.Coordinate do
  @moduledoc "The :coordinate kind. Multi-party interaction. See spec §3.5."

  @callback participate(role :: atom(), args :: map(), opts :: keyword()) ::
              {:ok, participation_ref :: reference()} | {:error, term()}

  @callback leave(participation_ref :: reference()) :: :ok
end
```

```elixir
# lib/llmagent/tool/kinds/spawn_kind.ex
defmodule LLMAgent.Tool.Kinds.SpawnKind do
  @moduledoc """
  The :spawn kind. Parent-child lifecycle ownership. See spec §3.6.

  The kind atom in `ToolAd.kinds` is `:spawn`; this module is named `SpawnKind`
  to avoid `Kernel.spawn/1` collisions in callers.
  """

  @callback spawn_child(spec :: term(), opts :: keyword()) ::
              {:ok, child_ref :: term()} | {:error, term()}

  @callback child_status(child_ref :: term()) :: term()

  @callback terminate_child(child_ref :: term(), reason :: term()) ::
              :ok | {:error, term()}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/llmagent/tool/kinds_behaviours_test.exs`
Expected: 6 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/tool/kinds/ test/llmagent/tool/kinds_behaviours_test.exs
git commit -m "Add six tool kind behaviours"
```

---

## Task 4: Kinds registry

**Files:**
- Create: `lib/llmagent/tool/kinds.ex`
- Create: `test/llmagent/tool/kinds_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/llmagent/tool/kinds_test.exs
defmodule LLMAgent.Tool.KindsTest do
  use ExUnit.Case, async: false   # mutates persistent_term
  alias LLMAgent.Tool.Kinds

  setup do
    Kinds.init_registry()
    :ok
  end

  describe "init_registry/0" do
    test "seeds the canonical six" do
      assert Kinds.list_kinds() |> Enum.sort() ==
               [:action, :compute, :coordinate, :query, :spawn, :stream]
    end

    test "kind atoms map to behaviour modules" do
      assert {:ok, LLMAgent.Tool.Kinds.Compute} = Kinds.behaviour_for(:compute)
      assert {:ok, LLMAgent.Tool.Kinds.SpawnKind} = Kinds.behaviour_for(:spawn)
    end
  end

  describe "register_kind/2" do
    test "adds a new kind" do
      defmodule MyKindBehaviour do
        @callback do_thing() :: :ok
      end

      :ok = Kinds.register_kind(:my_kind, MyKindBehaviour)
      assert {:ok, MyKindBehaviour} = Kinds.behaviour_for(:my_kind)

      Kinds.unregister_kind(:my_kind)
    end

    test "rejects non-module values" do
      assert {:error, :invalid_behaviour} = Kinds.register_kind(:bogus, "not a module")
    end
  end

  describe "behaviour_for/1" do
    test "returns :not_found for unknown kinds" do
      assert {:error, :not_found} = Kinds.behaviour_for(:nope)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/llmagent/tool/kinds_test.exs`
Expected: FAIL with "module LLMAgent.Tool.Kinds is not loaded".

- [ ] **Step 3: Implement the registry**

```elixir
# lib/llmagent/tool/kinds.ex
defmodule LLMAgent.Tool.Kinds do
  @moduledoc """
  Registry mapping kind atoms to their behaviour modules.

  Backed by `:persistent_term` for fast reads. Mutations rewrite the whole map.
  See spec §3.8.
  """

  @key :llmagent_tool_kinds

  @canonical %{
    query:      LLMAgent.Tool.Kinds.Query,
    action:     LLMAgent.Tool.Kinds.Action,
    stream:     LLMAgent.Tool.Kinds.Stream,
    compute:    LLMAgent.Tool.Kinds.Compute,
    coordinate: LLMAgent.Tool.Kinds.Coordinate,
    spawn:      LLMAgent.Tool.Kinds.SpawnKind
  }

  @doc "Seed the registry with the canonical six kinds."
  @spec init_registry() :: :ok
  def init_registry do
    :persistent_term.put(@key, @canonical)
    :ok
  end

  @spec list_kinds() :: [atom()]
  def list_kinds, do: get_all() |> Map.keys()

  @spec behaviour_for(atom()) :: {:ok, module()} | {:error, :not_found}
  def behaviour_for(kind) when is_atom(kind) do
    case Map.fetch(get_all(), kind) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, :not_found}
    end
  end

  @spec register_kind(atom(), module()) :: :ok | {:error, :invalid_behaviour}
  def register_kind(kind, behaviour_module)
      when is_atom(kind) and is_atom(behaviour_module) do
    Code.ensure_loaded(behaviour_module)

    cond do
      function_exported?(behaviour_module, :behaviour_info, 1) ->
        :persistent_term.put(@key, Map.put(get_all(), kind, behaviour_module))
        :ok

      true ->
        {:error, :invalid_behaviour}
    end
  end

  def register_kind(_kind, _other), do: {:error, :invalid_behaviour}

  @spec unregister_kind(atom()) :: :ok
  def unregister_kind(kind) when is_atom(kind) do
    :persistent_term.put(@key, Map.delete(get_all(), kind))
    :ok
  end

  defp get_all, do: :persistent_term.get(@key, %{})
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/llmagent/tool/kinds_test.exs`
Expected: 5 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/tool/kinds.ex test/llmagent/tool/kinds_test.exs
git commit -m "Add kinds registry seeded with the canonical six"
```

---

## Task 5: Adapter behaviour

**Files:**
- Create: `lib/llmagent/tool/adapter.ex`
- Create: `test/llmagent/tool/adapter_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/llmagent/tool/adapter_test.exs
defmodule LLMAgent.Tool.AdapterTest do
  use ExUnit.Case, async: true

  describe "behaviour callbacks" do
    test "all kind callbacks are declared" do
      callbacks = LLMAgent.Tool.Adapter.behaviour_info(:callbacks)

      expected = [
        query: 4, act: 5, subscribe: 5, unsubscribe: 3, compute: 4,
        participate: 5, leave: 3, spawn_child: 4, child_status: 3,
        terminate_child: 4
      ]

      for {fun, arity} <- expected do
        assert {fun, arity} in callbacks,
               "Adapter missing callback #{fun}/#{arity}"
      end
    end

    test "all callbacks are optional" do
      optional = LLMAgent.Tool.Adapter.behaviour_info(:optional_callbacks) |> Enum.sort()

      expected = [
        act: 5, child_status: 3, compute: 4, leave: 3, participate: 5,
        query: 4, spawn_child: 4, subscribe: 5, terminate_child: 4, unsubscribe: 3
      ] |> Enum.sort()

      assert optional == expected
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/llmagent/tool/adapter_test.exs`
Expected: FAIL with "module LLMAgent.Tool.Adapter is not loaded".

- [ ] **Step 3: Implement the behaviour**

```elixir
# lib/llmagent/tool/adapter.ex
defmodule LLMAgent.Tool.Adapter do
  @moduledoc """
  Behaviour for binding adapters. Each callback mirrors a kind's contract
  with the binding payload as the first argument.

  Adapters implement only the kinds their binding can carry. All callbacks
  are optional. See spec §4.1.
  """

  @callback query(payload :: term(), action :: String.t(), args :: map(),
                  opts :: keyword()) ::
              {:ok, term(), map()} | {:error, term()}

  @callback act(payload :: term(), action :: String.t(), args :: map(),
                idempotency_key :: String.t() | nil, opts :: keyword()) ::
              {:ok, term(), map()} | {:error, term()}

  @callback subscribe(payload :: term(), action :: String.t(), args :: map(),
                      subscriber :: pid(), opts :: keyword()) ::
              {:ok, reference()} | {:error, term()}

  @callback unsubscribe(payload :: term(), sub_ref :: reference(),
                        opts :: keyword()) :: :ok

  @callback compute(payload :: term(), action :: String.t(), args :: map(),
                    opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @callback participate(payload :: term(), role :: atom(), args :: map(),
                        opts :: keyword()) ::
              {:ok, reference()} | {:error, term()}

  @callback leave(payload :: term(), participation_ref :: reference(),
                  opts :: keyword()) :: :ok

  @callback spawn_child(payload :: term(), spec :: term(), opts :: keyword()) ::
              {:ok, child_ref :: term()} | {:error, term()}

  @callback child_status(payload :: term(), child_ref :: term(),
                         opts :: keyword()) :: term()

  @callback terminate_child(payload :: term(), child_ref :: term(),
                            reason :: term(), opts :: keyword()) ::
              :ok | {:error, term()}

  @optional_callbacks query: 4, act: 5, subscribe: 5, unsubscribe: 3, compute: 4,
                      participate: 5, leave: 3, spawn_child: 4, child_status: 3,
                      terminate_child: 4
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/llmagent/tool/adapter_test.exs`
Expected: 2 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/tool/adapter.ex test/llmagent/tool/adapter_test.exs
git commit -m "Add LLMAgent.Tool.Adapter behaviour"
```

---

## Task 6: `:module` adapter

**Files:**
- Create: `lib/llmagent/tool/adapter/module.ex`
- Create: `test/llmagent/tool/adapter/module_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/llmagent/tool/adapter/module_test.exs
defmodule LLMAgent.Tool.Adapter.ModuleTest do
  use ExUnit.Case, async: true

  defmodule StubTool do
    @behaviour LLMAgent.Tool.Kinds.Compute
    @behaviour LLMAgent.Tool.Kinds.Query
    @behaviour LLMAgent.Tool.Kinds.Action

    @impl LLMAgent.Tool.Kinds.Compute
    def compute("double", %{"n" => n}), do: {:ok, n * 2}

    @impl LLMAgent.Tool.Kinds.Query
    def query("now", _args), do: {:ok, :answer, %{source: "stub"}}

    @impl LLMAgent.Tool.Kinds.Action
    def act("write", %{"x" => x}, _key), do: {:ok, %{wrote: x}, %{}}
  end

  alias LLMAgent.Tool.Adapter.Module, as: ModAdapter

  describe "compute/4" do
    test "passes through to the module" do
      assert {:ok, 10} = ModAdapter.compute(StubTool, "double", %{"n" => 5}, [])
    end
  end

  describe "query/4" do
    test "passes through to the module" do
      assert {:ok, :answer, %{source: "stub"}} = ModAdapter.query(StubTool, "now", %{}, [])
    end
  end

  describe "act/5" do
    test "passes through with idempotency key" do
      assert {:ok, %{wrote: 1}, %{}} = ModAdapter.act(StubTool, "write", %{"x" => 1}, "key-1", [])
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/llmagent/tool/adapter/module_test.exs`
Expected: FAIL with "module LLMAgent.Tool.Adapter.Module is not loaded".

- [ ] **Step 3: Implement the adapter**

```elixir
# lib/llmagent/tool/adapter/module.ex
defmodule LLMAgent.Tool.Adapter.Module do
  @moduledoc """
  Adapter for `:module` bindings. The binding payload is a module that
  directly implements the relevant kind behaviour(s). Each adapter callback
  is a straight pass-through. See spec §4.2.
  """

  @behaviour LLMAgent.Tool.Adapter

  @impl true
  def query(mod, action, args, _opts), do: mod.query(action, args)

  @impl true
  def act(mod, action, args, idempotency_key, _opts),
    do: mod.act(action, args, idempotency_key)

  @impl true
  def subscribe(mod, action, args, subscriber, _opts),
    do: mod.subscribe(action, args, subscriber)

  @impl true
  def unsubscribe(mod, sub_ref, _opts), do: mod.unsubscribe(sub_ref)

  @impl true
  def compute(mod, action, args, _opts), do: mod.compute(action, args)

  @impl true
  def participate(mod, role, args, opts), do: mod.participate(role, args, opts)

  @impl true
  def leave(mod, participation_ref, _opts), do: mod.leave(participation_ref)

  @impl true
  def spawn_child(mod, spec, opts), do: mod.spawn_child(spec, opts)

  @impl true
  def child_status(mod, child_ref, _opts), do: mod.child_status(child_ref)

  @impl true
  def terminate_child(mod, child_ref, reason, _opts),
    do: mod.terminate_child(child_ref, reason)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/llmagent/tool/adapter/module_test.exs`
Expected: 3 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/tool/adapter/module.ex test/llmagent/tool/adapter/module_test.exs
git commit -m "Add :module adapter (pass-through to kind callbacks)"
```

---

## Task 7: Bindings registry

**Files:**
- Create: `lib/llmagent/tool/bindings.ex`
- Create: `test/llmagent/tool/bindings_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/llmagent/tool/bindings_test.exs
defmodule LLMAgent.Tool.BindingsTest do
  use ExUnit.Case, async: false   # mutates persistent_term
  alias LLMAgent.Tool.Bindings

  setup do
    Bindings.init_registry()
    :ok
  end

  describe "init_registry/0" do
    test "seeds :module" do
      assert Bindings.list_bindings() |> Enum.member?(:module)
      assert {:ok, LLMAgent.Tool.Adapter.Module} = Bindings.adapter_for(:module)
    end
  end

  describe "register/2 and unregister/1" do
    test "adds and removes a binding kind" do
      defmodule FakeAdapter do
        @behaviour LLMAgent.Tool.Adapter
      end

      :ok = Bindings.register(:fake, FakeAdapter)
      assert {:ok, FakeAdapter} = Bindings.adapter_for(:fake)

      :ok = Bindings.unregister(:fake)
      assert {:error, :not_found} = Bindings.adapter_for(:fake)
    end

    test "rejects non-module values" do
      assert {:error, :invalid_adapter} = Bindings.register(:bogus, "not a module")
    end
  end

  describe "adapter_for!/1" do
    test "returns the module for a registered binding" do
      assert LLMAgent.Tool.Adapter.Module = Bindings.adapter_for!(:module)
    end

    test "raises for an unknown binding" do
      assert_raise RuntimeError, ~r/binding kind .* not registered/, fn ->
        Bindings.adapter_for!(:nope)
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/llmagent/tool/bindings_test.exs`
Expected: FAIL with "module LLMAgent.Tool.Bindings is not loaded".

- [ ] **Step 3: Implement the registry**

```elixir
# lib/llmagent/tool/bindings.ex
defmodule LLMAgent.Tool.Bindings do
  @moduledoc """
  Registry mapping binding-kind atoms to their adapter modules.

  Same `:persistent_term` shape as `LLMAgent.Tool.Kinds`. See spec §4.4.

  This plan only ships the `:module` adapter; `:process`, `:remote`, `:http`,
  and `:mcp` are added in follow-on plans.
  """

  @key :llmagent_tool_bindings

  @canonical %{module: LLMAgent.Tool.Adapter.Module}

  @spec init_registry() :: :ok
  def init_registry do
    :persistent_term.put(@key, @canonical)
    :ok
  end

  @spec list_bindings() :: [atom()]
  def list_bindings, do: get_all() |> Map.keys()

  @spec adapter_for(atom()) :: {:ok, module()} | {:error, :not_found}
  def adapter_for(kind) when is_atom(kind) do
    case Map.fetch(get_all(), kind) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, :not_found}
    end
  end

  @spec adapter_for!(atom()) :: module()
  def adapter_for!(kind) do
    case adapter_for(kind) do
      {:ok, mod} -> mod
      {:error, :not_found} -> raise "binding kind #{inspect(kind)} not registered"
    end
  end

  @spec register(atom(), module()) :: :ok | {:error, :invalid_adapter}
  def register(kind, adapter_module) when is_atom(kind) and is_atom(adapter_module) do
    Code.ensure_loaded(adapter_module)

    if function_exported?(adapter_module, :module_info, 0) do
      :persistent_term.put(@key, Map.put(get_all(), kind, adapter_module))
      :ok
    else
      {:error, :invalid_adapter}
    end
  end

  def register(_kind, _other), do: {:error, :invalid_adapter}

  @spec unregister(atom()) :: :ok
  def unregister(kind) when is_atom(kind) do
    :persistent_term.put(@key, Map.delete(get_all(), kind))
    :ok
  end

  defp get_all, do: :persistent_term.get(@key, %{})
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/llmagent/tool/bindings_test.exs`
Expected: 5 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/tool/bindings.ex test/llmagent/tool/bindings_test.exs
git commit -m "Add bindings registry with :module adapter seeded"
```

---

## Task 8: Policy struct + decision algorithm

**Files:**
- Create: `lib/llmagent/tool/policy.ex`
- Create: `test/llmagent/tool/policy_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/llmagent/tool/policy_test.exs
defmodule LLMAgent.Tool.PolicyTest do
  use ExUnit.Case, async: true
  alias LLMAgent.{ToolAd, Tool.Policy}

  defp ad(overrides \\ %{}) do
    base = %{
      id: "test.ad",
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

  describe "decide/4 — allow/deny" do
    test "deny-by-default: empty allow forbids" do
      policy = %Policy{}
      assert {:error, :forbidden, :not_allowed} =
               Policy.decide(policy, ad(), :compute, "anything")
    end

    test "matching allow rule permits" do
      policy = %Policy{
        allow: [%{coordinate: "function.example", kinds: :any, actions: :any}]
      }
      assert :ok = Policy.decide(policy, ad(), :compute, "anything")
    end

    test "bare-string allow rule desugars" do
      policy = %Policy{allow: ["function.example"]}
      assert :ok = Policy.decide(policy, ad(), :compute, "anything")
    end

    test "explicit deny overrides allow" do
      policy = %Policy{
        allow: ["function.*"],
        deny:  [%{coordinate: "function.example", kinds: [:compute], actions: :any}]
      }
      assert {:error, :forbidden, :explicit_deny} =
               Policy.decide(policy, ad(), :compute, "x")
    end

    test "kinds filter narrows" do
      policy = %Policy{
        allow: [%{coordinate: "function.example", kinds: [:query], actions: :any}]
      }
      assert {:error, :forbidden, :not_allowed} =
               Policy.decide(policy, ad(), :compute, "x")
    end

    test "actions filter narrows" do
      policy = %Policy{
        allow: [%{coordinate: "function.example", kinds: :any, actions: ["only-this"]}]
      }
      assert :ok = Policy.decide(policy, ad(), :compute, "only-this")
      assert {:error, :forbidden, :not_allowed} =
               Policy.decide(policy, ad(), :compute, "other")
    end
  end

  describe "decide/4 — fidelity floor" do
    test "ad below fidelity_min is forbidden" do
      policy = %Policy{
        allow: ["function.example"],
        fidelity_min: :authoritative
      }
      assert {:error, :forbidden, :fidelity_too_low} =
               Policy.decide(policy, ad(%{fidelity: :trained}), :compute, "x")
    end

    test "ad at or above fidelity_min is allowed" do
      policy = %Policy{
        allow: ["function.example"],
        fidelity_min: :trained
      }
      assert :ok = Policy.decide(policy, ad(%{fidelity: :trained}), :compute, "x")
      assert :ok = Policy.decide(policy, ad(%{fidelity: :authoritative}), :compute, "x")
    end
  end

  describe "decide/4 — provenance" do
    test "source filter excludes non-matching" do
      policy = %Policy{
        allow: ["function.example"],
        provenance: %{source: ["trusted"], signed: false}
      }
      assert {:error, :forbidden, :provenance} =
               Policy.decide(policy, ad(), :compute, "x")
    end

    test "source filter accepts matching" do
      policy = %Policy{
        allow: ["function.example"],
        provenance: %{source: ["test"], signed: false}
      }
      assert :ok = Policy.decide(policy, ad(), :compute, "x")
    end

    test "signed required + signature missing is forbidden" do
      policy = %Policy{
        allow: ["function.example"],
        provenance: %{source: :any, signed: true}
      }
      assert {:error, :forbidden, :unsigned} =
               Policy.decide(policy, ad(), :compute, "x")
    end
  end

  describe "intersect/2" do
    test "merging policies takes the more restrictive bounds" do
      base = %Policy{
        allow: ["function.*"],
        fidelity_min: :trained
      }

      override = %Policy{
        allow: ["function.example"],
        fidelity_min: :authoritative,
        provenance: %{source: ["trusted"], signed: false}
      }

      merged = Policy.intersect(base, override)

      # The merged policy is the override (more restrictive) intersected with base allow
      assert merged.fidelity_min == :authoritative
      assert merged.provenance == %{source: ["trusted"], signed: false}
    end
  end

  describe "from_legacy_or_struct/1" do
    test "list of atoms desugars to legacy.* coordinates" do
      policy = Policy.from_legacy_or_struct([:bash, :web])

      assert policy.fidelity_min == :authoritative
      assert Enum.any?(policy.allow, &match?(%{coordinate: "legacy.bash"}, &1))
      assert Enum.any?(policy.allow, &match?(%{coordinate: "legacy.web"}, &1))
    end

    test "passes %Policy{} through" do
      p = %Policy{allow: ["x"]}
      assert ^p = Policy.from_legacy_or_struct(p)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/llmagent/tool/policy_test.exs`
Expected: FAIL with "module LLMAgent.Tool.Policy is not loaded".

- [ ] **Step 3: Implement Policy**

```elixir
# lib/llmagent/tool/policy.ex
defmodule LLMAgent.Tool.Policy do
  @moduledoc """
  Per-agent policy that gates the dispatcher. See spec §6.
  """

  alias LLMAgent.{ToolAd, ToolQuery}

  defstruct allow: [],
            deny: [],
            fidelity_min: :trained,
            provenance: nil

  @type policy_rule :: %{coordinate: String.t(), kinds: :any | [atom()], actions: :any | [String.t()]}

  @type t :: %__MODULE__{
          allow: [String.t() | policy_rule()],
          deny: [String.t() | policy_rule()],
          fidelity_min: :authoritative | :trained | :speculative,
          provenance: %{source: [String.t()] | :any, signed: boolean()} | nil
        }

  @fidelity_order %{speculative: 0, trained: 1, authoritative: 2}

  @doc """
  Decide whether a policy permits invoking (ad, kind, action).

  Returns `:ok` or `{:error, :forbidden, reason}`.
  """
  @spec decide(t(), ToolAd.t(), atom(), String.t()) ::
          :ok | {:error, :forbidden, atom()}
  def decide(%__MODULE__{} = policy, %ToolAd{} = ad, kind, action) do
    cond do
      Enum.any?(policy.deny, &rule_matches?(&1, ad, kind, action)) ->
        {:error, :forbidden, :explicit_deny}

      not Enum.any?(policy.allow, &rule_matches?(&1, ad, kind, action)) ->
        {:error, :forbidden, :not_allowed}

      not fidelity_ok?(ad, policy) ->
        {:error, :forbidden, :fidelity_too_low}

      not provenance_source_ok?(ad, policy) ->
        {:error, :forbidden, :provenance}

      not provenance_signed_ok?(ad, policy) ->
        {:error, :forbidden, :unsigned}

      true ->
        :ok
    end
  end

  @doc "Intersect (narrow) two policies. The result is at least as restrictive as either input."
  @spec intersect(t(), t()) :: t()
  def intersect(%__MODULE__{} = base, %__MODULE__{} = override) do
    %__MODULE__{
      allow: intersect_rule_lists(base.allow, override.allow),
      deny: base.deny ++ override.deny,
      fidelity_min: stricter_fidelity(base.fidelity_min, override.fidelity_min),
      provenance: stricter_provenance(base.provenance, override.provenance)
    }
  end

  @doc "Translate the legacy `[:atom, ...]` allowed_tools or pass through a %Policy{}."
  @spec from_legacy_or_struct([atom()] | t()) :: t()
  def from_legacy_or_struct(%__MODULE__{} = p), do: p

  def from_legacy_or_struct(list) when is_list(list) do
    %__MODULE__{
      allow:
        Enum.map(list, fn name when is_atom(name) ->
          %{coordinate: "legacy.#{name}", kinds: :any, actions: :any}
        end),
      fidelity_min: :authoritative,
      provenance: %{source: :any, signed: false}
    }
  end

  # --- internal helpers ---

  defp rule_matches?(rule, %ToolAd{} = ad, kind, action) do
    %{coordinate: coord, kinds: kinds, actions: actions} = normalize_rule(rule)

    ToolQuery.coordinate_matches?(coord, ad.coordinate) and
      kinds_match?(kinds, kind) and
      actions_match?(actions, action)
  end

  defp normalize_rule(s) when is_binary(s),
    do: %{coordinate: s, kinds: :any, actions: :any}

  defp normalize_rule(%{} = m), do: Map.merge(%{kinds: :any, actions: :any}, m)

  defp kinds_match?(:any, _kind), do: true
  defp kinds_match?(list, kind) when is_list(list), do: kind in list

  defp actions_match?(:any, _action), do: true
  defp actions_match?(list, action) when is_list(list), do: action in list

  defp fidelity_ok?(%ToolAd{fidelity: f}, %__MODULE__{fidelity_min: m}),
    do: @fidelity_order[f] >= @fidelity_order[m]

  defp provenance_source_ok?(_ad, %__MODULE__{provenance: nil}), do: true
  defp provenance_source_ok?(_ad, %__MODULE__{provenance: %{source: :any}}), do: true

  defp provenance_source_ok?(%ToolAd{provenance: %{source: src}}, %__MODULE__{provenance: %{source: list}})
       when is_list(list),
       do: src in list

  defp provenance_signed_ok?(_ad, %__MODULE__{provenance: nil}), do: true
  defp provenance_signed_ok?(_ad, %__MODULE__{provenance: %{signed: false}}), do: true

  defp provenance_signed_ok?(%ToolAd{provenance: %{signature: nil}}, %__MODULE__{provenance: %{signed: true}}),
    do: false

  defp provenance_signed_ok?(_ad, _policy), do: true

  defp stricter_fidelity(a, b) do
    if @fidelity_order[a] >= @fidelity_order[b], do: a, else: b
  end

  defp stricter_provenance(nil, b), do: b
  defp stricter_provenance(a, nil), do: a

  defp stricter_provenance(%{source: a_src, signed: a_sgn}, %{source: b_src, signed: b_sgn}) do
    %{
      source: stricter_source(a_src, b_src),
      signed: a_sgn or b_sgn
    }
  end

  defp stricter_source(:any, b), do: b
  defp stricter_source(a, :any), do: a
  defp stricter_source(a, b) when is_list(a) and is_list(b), do: Enum.filter(a, &(&1 in b))

  defp intersect_rule_lists([], override), do: override
  defp intersect_rule_lists(base, []), do: base
  defp intersect_rule_lists(_base, override), do: override
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/llmagent/tool/policy_test.exs`
Expected: 13 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/tool/policy.ex test/llmagent/tool/policy_test.exs
git commit -m "Add LLMAgent.Tool.Policy with decide/intersect/legacy translation"
```

---

## Task 9: Discovery — register / find_one / find_all / ranking

**Files:**
- Create: `lib/llmagent/tools/discovery.ex`
- Create: `test/llmagent/tools/discovery_test.exs`

This task brings up Discovery as a GenServer with basic CRUD and ranking. Subscriptions, lease eviction, and the tuple-space announcement consumer come in later tasks.

- [ ] **Step 1: Write the failing test**

```elixir
# test/llmagent/tools/discovery_test.exs
defmodule LLMAgent.Tools.DiscoveryTest do
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/llmagent/tools/discovery_test.exs`
Expected: FAIL with "module LLMAgent.Tools.Discovery is not loaded".

- [ ] **Step 3: Implement Discovery (CRUD + ranking only — subscriptions/leases/announce in later tasks)**

```elixir
# lib/llmagent/tools/discovery.ex
defmodule LLMAgent.Tools.Discovery do
  @moduledoc """
  Tool discovery registry. Stores `LLMAgent.ToolAd` records and serves
  pattern-matching queries. See spec §2 and §5.

  This module is built up across plan tasks 9–14. Task 9 adds register / update
  / unregister / renew / find_one / find_all with ranking.

  Storage: ETS table owned by this GenServer, keyed by ad_id.
  """

  use GenServer

  alias LLMAgent.{ToolAd, ToolQuery}

  @table :llmagent_tool_discovery
  @fidelity_order %{authoritative: 2, trained: 1, speculative: 0}

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec reset!() :: :ok
  def reset!, do: GenServer.call(__MODULE__, :reset)

  @spec register(ToolAd.t()) :: :ok | {:error, term()}
  def register(%ToolAd{} = ad), do: GenServer.call(__MODULE__, {:register, ad})

  @spec update(ToolAd.t()) :: :ok | {:error, term()}
  def update(%ToolAd{} = ad), do: GenServer.call(__MODULE__, {:update, ad})

  @spec unregister(binary()) :: :ok
  def unregister(ad_id) when is_binary(ad_id),
    do: GenServer.call(__MODULE__, {:unregister, ad_id})

  @spec renew(binary(), DateTime.t()) :: :ok | {:error, :not_found}
  def renew(ad_id, %DateTime{} = expires_at),
    do: GenServer.call(__MODULE__, {:renew, ad_id, expires_at})

  @spec find_one(ToolQuery.t()) :: {:ok, ToolAd.t()} | {:error, :not_found}
  def find_one(%ToolQuery{} = q) do
    case find_all(q) do
      {:ok, [first | _]} -> {:ok, first}
      {:ok, []} -> {:error, :not_found}
    end
  end

  @spec find_all(ToolQuery.t()) :: {:ok, [ToolAd.t()]}
  def find_all(%ToolQuery{} = q) do
    ads =
      :ets.tab2list(@table)
      |> Enum.map(fn {_id, ad} -> ad end)
      |> Enum.filter(&matches?(&1, q))
      |> Enum.sort_by(&rank_key/1)
      |> apply_limit(q.limit)

    {:ok, ads}
  end

  # --- Validation (used by register/update; will also be used by §5.2 announcement consumer) ---

  @spec validate(ToolAd.t()) :: :ok | {:error, {:invalid_ad, atom(), String.t()}}
  def validate(%ToolAd{} = ad) do
    cond do
      not (is_binary(ad.coordinate) and String.contains?(ad.coordinate, ".") and ad.coordinate != "") ->
        {:error, {:invalid_ad, :coordinate, "must be non-empty dotted string"}}

      not (is_list(ad.kinds) and ad.kinds != [] and Enum.all?(ad.kinds, &is_atom/1)) ->
        {:error, {:invalid_ad, :kinds, "must be non-empty list of atoms"}}

      not valid_fidelity?(ad.fidelity) ->
        {:error, {:invalid_ad, :fidelity, "must be :authoritative | :trained | :speculative"}}

      not valid_lease?(ad.lease) ->
        {:error, {:invalid_ad, :lease, "must be :permanent or {:expires_at, future DateTime}"}}

      not valid_provenance?(ad.provenance) ->
        {:error, {:invalid_ad, :provenance, "must include :source and :produced_at"}}

      true ->
        :ok
    end
  end

  defp valid_fidelity?(f), do: f in [:authoritative, :trained, :speculative]
  defp valid_lease?(:permanent), do: true
  defp valid_lease?({:expires_at, %DateTime{}}), do: true
  defp valid_lease?(_), do: false

  defp valid_provenance?(%{source: src, produced_at: %DateTime{}}) when not is_nil(src), do: true
  defp valid_provenance?(_), do: false

  # --- GenServer ---

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :set,
        :protected,
        :named_table,
        read_concurrency: true
      ])

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  def handle_call({:register, ad}, _from, state) do
    cond do
      :ets.member(@table, ad.id) ->
        {:reply, {:error, :duplicate_id}, state}

      true ->
        case validate(ad) do
          :ok ->
            :ets.insert(@table, {ad.id, ad})
            {:reply, :ok, state}

          {:error, _} = err ->
            {:reply, err, state}
        end
    end
  end

  def handle_call({:update, ad}, _from, state) do
    case validate(ad) do
      :ok ->
        :ets.insert(@table, {ad.id, ad})
        {:reply, :ok, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:unregister, ad_id}, _from, state) do
    :ets.delete(@table, ad_id)
    {:reply, :ok, state}
  end

  def handle_call({:renew, ad_id, expires_at}, _from, state) do
    case :ets.lookup(@table, ad_id) do
      [{^ad_id, ad}] ->
        :ets.insert(@table, {ad_id, %{ad | lease: {:expires_at, expires_at}}})
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # --- Matching / ranking ---

  defp matches?(%ToolAd{} = ad, %ToolQuery{} = q) do
    ToolQuery.coordinate_matches?(q.coordinate, ad.coordinate) and
      kinds_ok?(q.kinds, ad.kinds) and
      fidelity_ok?(q.fidelity_min, ad.fidelity)
  end

  defp kinds_ok?(:any, _ad_kinds), do: true
  defp kinds_ok?(required, ad_kinds) when is_list(required),
    do: Enum.all?(required, &(&1 in ad_kinds))

  defp fidelity_ok?(min, ad_fid) do
    @fidelity_order[ad_fid] >= @fidelity_order[min]
  end

  defp rank_key(%ToolAd{fidelity: f, confidence: c, provenance: %{produced_at: t}}) do
    # Higher fidelity first → invert. Then higher confidence → invert. Then more recent.
    {-(@fidelity_order[f] || 0), -(c || 0.0), -DateTime.to_unix(t, :microsecond)}
  end

  defp apply_limit(list, :all), do: list
  defp apply_limit(list, n) when is_integer(n) and n > 0, do: Enum.take(list, n)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/llmagent/tools/discovery_test.exs`
Expected: 13 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/tools/discovery.ex test/llmagent/tools/discovery_test.exs
git commit -m "Add Discovery GenServer with register/update/find/rank"
```

---

## Task 10: Discovery — subscriptions

**Files:**
- Modify: `lib/llmagent/tools/discovery.ex`
- Modify: `test/llmagent/tools/discovery_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/llmagent/tools/discovery_test.exs`:

```elixir
  describe "subscribe/2" do
    test "subscriber receives :tool_added matching the query" do
      query = ToolQuery.new(%{coordinate: "function.notify.*"})
      :ok = Discovery.subscribe(query, self())

      a = ad(%{id: "n1", coordinate: "function.notify.one"})
      :ok = Discovery.register(a)

      assert_receive {:tool_added, "n1", "function.notify.one"}, 500
    end

    test "subscriber does NOT receive non-matching events" do
      query = ToolQuery.new(%{coordinate: "function.subscribe-me.*"})
      :ok = Discovery.subscribe(query, self())

      :ok = Discovery.register(ad(%{id: "off", coordinate: "function.other.x"}))

      refute_receive {:tool_added, "off", _}, 200
    end

    test "subscriber receives :tool_updated and :tool_removed" do
      query = ToolQuery.new(%{coordinate: "function.lifecycle.*"})
      :ok = Discovery.subscribe(query, self())

      a = ad(%{id: "lc", coordinate: "function.lifecycle.x"})
      :ok = Discovery.register(a)
      assert_receive {:tool_added, "lc", _}, 500

      :ok = Discovery.update(%{a | meta: %{v: 2}})
      assert_receive {:tool_updated, "lc", _}, 500

      :ok = Discovery.unregister("lc")
      assert_receive {:tool_removed, "lc", _, :unregistered}, 500
    end

    test "subscription is cleaned up when subscriber dies" do
      parent = self()
      query = ToolQuery.new(%{coordinate: "function.dead.*"})

      child =
        spawn(fn ->
          :ok = Discovery.subscribe(query, self())
          send(parent, :subscribed)

          receive do
            :stop -> :ok
          after
            5_000 -> :ok
          end
        end)

      assert_receive :subscribed, 500
      ref = Process.monitor(child)
      send(child, :stop)
      assert_receive {:DOWN, ^ref, :process, ^child, _}, 500

      # After the subscriber is gone, registering a matching ad should not crash Discovery.
      :ok = Discovery.register(ad(%{id: "after-death", coordinate: "function.dead.x"}))

      assert {:ok, _} = Discovery.find_one(ToolQuery.new(%{coordinate: "function.dead.x"}))
    end
  end
```

- [ ] **Step 2: Run tests to verify failure**

Run: `mix test test/llmagent/tools/discovery_test.exs`
Expected: 4 new tests fail with "Discovery does not export subscribe/2" or similar.

- [ ] **Step 3: Implement subscriptions in Discovery**

Modify `lib/llmagent/tools/discovery.ex`:

1. Add `subscribe/2` to public API:

```elixir
  @spec subscribe(ToolQuery.t(), pid()) :: :ok
  def subscribe(%ToolQuery{} = q, subscriber) when is_pid(subscriber),
    do: GenServer.call(__MODULE__, {:subscribe, q, subscriber})
```

2. Replace the existing `init/1` with one that initializes the subscribers map:

```elixir
  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])

    {:ok, %{table: table, subscribers: %{}}}
  end
```

3. Add the subscribe handle_call:

```elixir
  def handle_call({:subscribe, query, pid}, _from, state) do
    monitor_ref = Process.monitor(pid)
    subs = Map.put(state.subscribers, monitor_ref, {pid, query})
    {:reply, :ok, %{state | subscribers: subs}}
  end
```

4. Add a `:DOWN` handler:

```elixir
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}
  end
```

5. Modify the existing `register`/`update`/`unregister` handle_call clauses to emit events. Replace them with:

```elixir
  def handle_call({:register, ad}, _from, state) do
    cond do
      :ets.member(@table, ad.id) ->
        {:reply, {:error, :duplicate_id}, state}

      true ->
        case validate(ad) do
          :ok ->
            :ets.insert(@table, {ad.id, ad})
            notify_subscribers(state.subscribers, ad, :tool_added)
            {:reply, :ok, state}

          {:error, _} = err ->
            {:reply, err, state}
        end
    end
  end

  def handle_call({:update, ad}, _from, state) do
    case validate(ad) do
      :ok ->
        :ets.insert(@table, {ad.id, ad})
        notify_subscribers(state.subscribers, ad, :tool_updated)
        {:reply, :ok, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:unregister, ad_id}, _from, state) do
    case :ets.lookup(@table, ad_id) do
      [{^ad_id, ad}] ->
        :ets.delete(@table, ad_id)
        notify_subscribers_removed(state.subscribers, ad, :unregistered)

      [] ->
        :ok
    end

    {:reply, :ok, state}
  end
```

6. Add the notify helpers (private functions):

```elixir
  defp notify_subscribers(subs, %ToolAd{} = ad, event) do
    for {_ref, {pid, query}} <- subs, matches?(ad, query) do
      send(pid, {event, ad.id, ad.coordinate})
    end

    :ok
  end

  defp notify_subscribers_removed(subs, %ToolAd{} = ad, reason) do
    for {_ref, {pid, query}} <- subs, matches?(ad, query) do
      send(pid, {:tool_removed, ad.id, ad.coordinate, reason})
    end

    :ok
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/llmagent/tools/discovery_test.exs`
Expected: 17 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/tools/discovery.ex test/llmagent/tools/discovery_test.exs
git commit -m "Add Discovery subscriptions with auto-cleanup on subscriber death"
```

---

## Task 11: Discovery — lease eviction sweeper

**Files:**
- Modify: `lib/llmagent/tools/discovery.ex`
- Modify: `test/llmagent/tools/discovery_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/llmagent/tools/discovery_test.exs`:

```elixir
  describe "lease eviction" do
    test "expired ads are evicted by manual sweep and emit :tool_removed :lease_expired" do
      past = DateTime.add(DateTime.utc_now(), -10)
      a = ad(%{id: "exp", coordinate: "function.exp", lease: {:expires_at, past}})
      :ok = Discovery.register(a)

      :ok = Discovery.subscribe(ToolQuery.new(%{coordinate: "function.exp"}), self())

      :ok = Discovery.sweep_now()

      assert_receive {:tool_removed, "exp", "function.exp", :lease_expired}, 500
      assert {:error, :not_found} =
               Discovery.find_one(ToolQuery.new(%{coordinate: "function.exp"}))
    end

    test "permanent ads survive sweep" do
      a = ad(%{id: "perm", coordinate: "function.perm", lease: :permanent})
      :ok = Discovery.register(a)
      :ok = Discovery.sweep_now()

      assert {:ok, %{id: "perm"}} =
               Discovery.find_one(ToolQuery.new(%{coordinate: "function.perm"}))
    end

    test "future leases survive sweep" do
      future = DateTime.add(DateTime.utc_now(), 3600)
      a = ad(%{id: "fut", coordinate: "function.fut", lease: {:expires_at, future}})
      :ok = Discovery.register(a)
      :ok = Discovery.sweep_now()

      assert {:ok, %{id: "fut"}} =
               Discovery.find_one(ToolQuery.new(%{coordinate: "function.fut"}))
    end
  end
```

- [ ] **Step 2: Run tests to verify failure**

Run: `mix test test/llmagent/tools/discovery_test.exs`
Expected: 3 new tests fail with "Discovery does not export sweep_now/0".

- [ ] **Step 3: Implement sweeper**

Modify `lib/llmagent/tools/discovery.ex`:

1. Add a `sweep_interval_ms` option to `start_link/1` and `init/1`. Update `init/1`:

```elixir
  @impl true
  def init(opts) do
    table =
      :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])

    interval = Keyword.get(opts, :sweep_interval_ms, 30_000)
    schedule_sweep(interval)

    {:ok, %{table: table, subscribers: %{}, sweep_interval_ms: interval}}
  end

  defp schedule_sweep(interval) when is_integer(interval) and interval > 0,
    do: Process.send_after(self(), :sweep, interval)

  defp schedule_sweep(_), do: :ok
```

2. Add the sweep API:

```elixir
  @spec sweep_now() :: :ok
  def sweep_now, do: GenServer.call(__MODULE__, :sweep_now)
```

3. Add handlers:

```elixir
  def handle_call(:sweep_now, _from, state) do
    do_sweep(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    do_sweep(state)
    schedule_sweep(state.sweep_interval_ms)
    {:noreply, state}
  end
```

4. Add the do_sweep private function:

```elixir
  defp do_sweep(state) do
    now = DateTime.utc_now()

    expired =
      :ets.tab2list(@table)
      |> Enum.flat_map(fn
        {_id, %ToolAd{lease: {:expires_at, ts}} = ad} ->
          if DateTime.compare(ts, now) == :lt, do: [ad], else: []

        _ ->
          []
      end)

    for ad <- expired do
      :ets.delete(@table, ad.id)
      notify_subscribers_removed(state.subscribers, ad, :lease_expired)
    end

    :ok
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/llmagent/tools/discovery_test.exs`
Expected: 20 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/tools/discovery.ex test/llmagent/tools/discovery_test.exs
git commit -m "Add Discovery lease eviction sweeper"
```

---

## Task 12: Discovery — tuple-space announcement consumer

**Files:**
- Modify: `lib/llmagent/tools/discovery.ex`
- Modify: `test/llmagent/tools/discovery_test.exs`

This task wires Discovery's announcement consumer to a tuple space. We use a dedicated tuple space name (`:tool_announce`) per spec §5.2 to avoid mixing tool announcements with general agent traffic.

- [ ] **Step 1: Write the failing test**

Append to `test/llmagent/tools/discovery_test.exs`:

```elixir
  describe "tuple space announcement consumer" do
    setup do
      # The announcement space is a normal LLMAgent.TupleSpace; ensure it's started.
      case LLMAgent.TupleSpace.list_spaces() |> Enum.member?(:tool_announce) do
        true -> :ok
        false -> {:ok, _} = LLMAgent.TupleSpace.start_space(:tool_announce)
      end

      :ok
    end

    test "absorbs an announcement tuple into the registry" do
      a = ad(%{id: "anno1", coordinate: "function.announced"})

      :ok = Discovery.subscribe(ToolQuery.new(%{coordinate: "function.announced"}), self())

      :ok = LLMAgent.TupleSpace.out(:tool_announce, {:tool_announce, "anno1", a})

      assert_receive {:tool_added, "anno1", "function.announced"}, 1_000

      assert {:ok, %{id: "anno1"}} =
               Discovery.find_one(ToolQuery.new(%{coordinate: "function.announced"}))
    end

    test "withdraw tuple unregisters the ad" do
      a = ad(%{id: "anno2", coordinate: "function.announced2"})
      :ok = LLMAgent.TupleSpace.out(:tool_announce, {:tool_announce, "anno2", a})

      Process.sleep(50)

      :ok = Discovery.subscribe(ToolQuery.new(%{coordinate: "function.announced2"}), self())
      :ok = LLMAgent.TupleSpace.out(:tool_announce, {:tool_withdraw, "anno2"})

      assert_receive {:tool_removed, "anno2", "function.announced2", :unregistered}, 1_000
    end
  end
```

- [ ] **Step 2: Run tests to verify failure**

Run: `mix test test/llmagent/tools/discovery_test.exs`
Expected: 2 new tests fail (announcement tuples are not absorbed).

- [ ] **Step 3: Implement the announcement consumer**

Modify `lib/llmagent/tools/discovery.ex`:

1. Add module attribute and start a consumer task in `init/1`:

```elixir
  @announce_space :tool_announce

  @impl true
  def init(opts) do
    table =
      :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])

    interval = Keyword.get(opts, :sweep_interval_ms, 30_000)
    schedule_sweep(interval)

    consume_announcements? = Keyword.get(opts, :consume_announcements, true)
    if consume_announcements?, do: schedule_announce_poll()

    {:ok,
     %{
       table: table,
       subscribers: %{},
       sweep_interval_ms: interval,
       consume_announcements: consume_announcements?
     }}
  end

  defp schedule_announce_poll, do: Process.send_after(self(), :poll_announcements, 100)
```

2. Add the poll handler. It uses `in_nowait` to drain all pending announcements without blocking:

```elixir
  @impl true
  def handle_info(:poll_announcements, state) do
    drain_announcements(state)

    if state.consume_announcements,
      do: schedule_announce_poll()

    {:noreply, state}
  end
```

3. Add the drain function and handlers for both announce and withdraw:

```elixir
  defp drain_announcements(state) do
    case ensure_announce_space() do
      :ok ->
        drain_loop(state)

      {:error, _} ->
        :ok
    end
  end

  defp drain_loop(state) do
    case LLMAgent.TupleSpace.in_nowait(@announce_space, {:tool_announce, :_, :_}) do
      {:ok, {:tool_announce, _id, %ToolAd{} = ad}} ->
        absorb_announcement(state, ad)
        drain_loop(state)

      {:ok, _other} ->
        # Malformed; drop
        drain_loop(state)

      {:error, :no_match} ->
        drain_withdrawals(state)
    end
  end

  defp drain_withdrawals(state) do
    case LLMAgent.TupleSpace.in_nowait(@announce_space, {:tool_withdraw, :_}) do
      {:ok, {:tool_withdraw, ad_id}} when is_binary(ad_id) ->
        case :ets.lookup(@table, ad_id) do
          [{^ad_id, ad}] ->
            :ets.delete(@table, ad_id)
            notify_subscribers_removed(state.subscribers, ad, :unregistered)

          [] ->
            :ok
        end

        drain_withdrawals(state)

      {:ok, _other} ->
        drain_withdrawals(state)

      {:error, :no_match} ->
        :ok
    end
  end

  defp absorb_announcement(state, %ToolAd{} = ad) do
    case validate(ad) do
      :ok ->
        existed? = :ets.member(@table, ad.id)
        :ets.insert(@table, {ad.id, ad})

        event = if existed?, do: :tool_updated, else: :tool_added
        notify_subscribers(state.subscribers, ad, event)

      {:error, _} ->
        :ok
    end
  end

  defp ensure_announce_space do
    case LLMAgent.TupleSpace.list_spaces() do
      spaces when is_list(spaces) ->
        if @announce_space in spaces, do: :ok, else: ensure_started()

      _ ->
        {:error, :tuple_space_unavailable}
    end
  rescue
    _ -> {:error, :tuple_space_unavailable}
  end

  defp ensure_started do
    case LLMAgent.TupleSpace.start_space(@announce_space) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      other -> other
    end
  end
```

4. Quick check: `LLMAgent.TupleSpace.in_nowait/2` should match the existing public API. If the actual function name differs (e.g., it's `in_nowait/2` vs `in_/2` plus a 0 timeout), inspect `lib/llmagent/tuple_space.ex` for the canonical call and adjust the calls above. The test in step 1 already uses `out/2`, `start_space/1`, and `list_spaces/0`; verify those exist too.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/llmagent/tools/discovery_test.exs`
Expected: 22 tests, 0 failures.

If `in_nowait` returns a different shape than `{:ok, tuple} | {:error, :no_match}`, adjust the pattern match in `drain_loop` / `drain_withdrawals` to match. The test should still drive convergence.

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/tools/discovery.ex test/llmagent/tools/discovery_test.exs
git commit -m "Add Discovery tuple-space announcement consumer"
```

---

## Task 13: Dispatcher

**Files:**
- Create: `lib/llmagent/tool/dispatcher.ex`
- Create: `test/llmagent/tool/dispatcher_test.exs`

The Dispatcher is the trust + observability choke point. It resolves an ad (or coordinate), checks policy, checks kind, looks up the adapter, and invokes. It also emits telemetry.

- [ ] **Step 1: Write the failing test**

```elixir
# test/llmagent/tool/dispatcher_test.exs
defmodule LLMAgent.Tool.DispatcherTest do
  use ExUnit.Case, async: false

  alias LLMAgent.{ToolAd, ToolQuery, Tool.Dispatcher, Tool.Policy, Tools.Discovery}

  defmodule StubCompute do
    @behaviour LLMAgent.Tool.Kinds.Compute
    @impl true
    def compute("double", %{"n" => n}), do: {:ok, n * 2}
    def compute(_, _), do: {:error, :unknown_action}
  end

  defmodule StubAction do
    @behaviour LLMAgent.Tool.Kinds.Action
    @impl true
    def act("write", %{"v" => v}, key), do: {:ok, %{wrote: v, key: key}, %{}}
  end

  setup do
    case Process.whereis(Discovery) do
      nil -> {:ok, _} = Discovery.start_link(consume_announcements: false)
      _ -> Discovery.reset!()
    end

    LLMAgent.Tool.Bindings.init_registry()
    LLMAgent.Tool.Kinds.init_registry()
    :ok
  end

  defp ad(overrides) do
    base = %{
      id: "disp." <> Integer.to_string(System.unique_integer([:positive])),
      coordinate: "function.disp",
      kinds: [:compute],
      binding: {:module, StubCompute},
      operational: %{actions: %{}},
      constraint: %{idempotency: %{}, blast_radius: %{}},
      affordance: %{declared: [], learned: [], open: false},
      fidelity: :authoritative,
      provenance: %{source: "test", produced_at: DateTime.utc_now(), based_on: [], signature: nil},
      lease: :permanent
    }

    ToolAd.new(Map.merge(base, overrides))
  end

  describe "compute/4 — happy path" do
    test "dispatches to the :module adapter and returns the result" do
      a = ad(%{coordinate: "function.compute.double", binding: {:module, StubCompute}})
      :ok = Discovery.register(a)

      policy = %Policy{
        allow: ["function.compute.*"],
        fidelity_min: :authoritative
      }

      assert {:ok, 6} =
               Dispatcher.compute("function.compute.double", "double", %{"n" => 3}, policy: policy)
    end

    test "accepts an ad directly" do
      a = ad(%{coordinate: "function.direct", binding: {:module, StubCompute}})
      policy = %Policy{allow: ["function.direct"], fidelity_min: :authoritative}

      assert {:ok, 8} = Dispatcher.compute(a, "double", %{"n" => 4}, policy: policy)
    end
  end

  describe "policy enforcement" do
    test "deny-by-default forbids when policy.allow is empty" do
      a = ad(%{coordinate: "function.gated", binding: {:module, StubCompute}})
      :ok = Discovery.register(a)

      assert {:error, :forbidden, :not_allowed} =
               Dispatcher.compute("function.gated", "double", %{"n" => 1}, policy: %Policy{})
    end
  end

  describe "kind check" do
    test "returns :kind_not_supported when ad doesn't implement requested kind" do
      a = ad(%{coordinate: "function.action_only", kinds: [:action], binding: {:module, StubAction}})
      :ok = Discovery.register(a)

      policy = %Policy{allow: ["function.action_only"], fidelity_min: :authoritative}

      assert {:error, :kind_not_supported} =
               Dispatcher.compute("function.action_only", "x", %{}, policy: policy)
    end
  end

  describe "binding lookup" do
    test "returns :binding_not_supported for unknown binding kind" do
      a = ad(%{
        coordinate: "function.weirdbind",
        binding: {:nonexistent_binding, :something},
        kinds: [:compute]
      })

      :ok = Discovery.register(a)
      policy = %Policy{allow: ["function.weirdbind"], fidelity_min: :authoritative}

      assert {:error, :binding_not_supported} =
               Dispatcher.compute("function.weirdbind", "x", %{}, policy: policy)
    end
  end

  describe "act/5" do
    test "passes idempotency key through" do
      a = ad(%{
        coordinate: "function.acttest",
        kinds: [:action],
        binding: {:module, StubAction}
      })

      :ok = Discovery.register(a)
      policy = %Policy{allow: ["function.acttest"], fidelity_min: :authoritative}

      assert {:ok, %{wrote: 7, key: "k1"}, %{}} =
               Dispatcher.act("function.acttest", "write", %{"v" => 7}, "k1", policy: policy)
    end
  end

  describe "telemetry" do
    test "emits [:llmagent, :tool, :compute] on dispatch" do
      a = ad(%{coordinate: "function.tele", binding: {:module, StubCompute}})
      :ok = Discovery.register(a)

      policy = %Policy{allow: ["function.tele"], fidelity_min: :authoritative}

      handler_id = "test-handler-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler_id,
        [:llmagent, :tool, :compute],
        fn _name, _measurements, metadata, _config -> send(parent, {:telemetry, metadata}) end,
        nil
      )

      _ = Dispatcher.compute("function.tele", "double", %{"n" => 2}, policy: policy)

      assert_receive {:telemetry, %{coordinate: "function.tele", action: "double"}}, 500

      :telemetry.detach(handler_id)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/llmagent/tool/dispatcher_test.exs`
Expected: FAIL with "module LLMAgent.Tool.Dispatcher is not loaded".

- [ ] **Step 3: Implement Dispatcher**

```elixir
# lib/llmagent/tool/dispatcher.ex
defmodule LLMAgent.Tool.Dispatcher do
  @moduledoc """
  Single entry point for invoking tools. Resolves coordinates → ads,
  enforces policy, checks kinds, looks up binding adapters, dispatches.
  Emits telemetry on every call. See spec §4.3.
  """

  alias LLMAgent.{ToolAd, ToolQuery, Tool.Bindings, Tool.Policy, Tools.Discovery}

  @type result :: term()
  @type opts :: keyword()

  @spec query(ToolAd.t() | String.t(), String.t(), map(), opts()) :: result()
  def query(ad_or_coord, action, args, opts \\ []),
    do: dispatch(ad_or_coord, :query, action, args, opts)

  @spec act(ToolAd.t() | String.t(), String.t(), map(), String.t() | nil, opts()) :: result()
  def act(ad_or_coord, action, args, idempotency_key \\ nil, opts \\ []) do
    dispatch(ad_or_coord, :action, action, args, [{:idempotency_key, idempotency_key} | opts])
  end

  @spec subscribe(ToolAd.t() | String.t(), String.t(), map(), pid(), opts()) :: result()
  def subscribe(ad_or_coord, action, args, subscriber, opts \\ []),
    do: dispatch(ad_or_coord, :stream, action, args, [{:subscriber, subscriber} | opts])

  @spec compute(ToolAd.t() | String.t(), String.t(), map(), opts()) :: result()
  def compute(ad_or_coord, action, args, opts \\ []),
    do: dispatch(ad_or_coord, :compute, action, args, opts)

  @spec participate(ToolAd.t() | String.t(), atom(), map(), opts()) :: result()
  def participate(ad_or_coord, role, args, opts \\ []),
    do: dispatch(ad_or_coord, :coordinate, role, args, opts)

  @spec spawn_child(ToolAd.t() | String.t(), term(), opts()) :: result()
  def spawn_child(ad_or_coord, spec, opts \\ []),
    do: dispatch(ad_or_coord, :spawn, spec, %{}, opts)

  # --- core dispatch ---

  defp dispatch(ad_or_coord, kind, action_or_role_or_spec, args, opts) do
    with {:ok, ad} <- resolve(ad_or_coord),
         policy = Keyword.get(opts, :policy, %Policy{}),
         action_str = action_to_string(action_or_role_or_spec),
         :ok <- Policy.decide(policy, ad, kind, action_str),
         :ok <- check_kind(ad, kind),
         {:ok, adapter, payload} <- resolve_adapter(ad) do
      result = invoke(adapter, kind, payload, action_or_role_or_spec, args, opts)

      :telemetry.execute(
        [:llmagent, :tool, kind],
        %{},
        %{
          coordinate: ad.coordinate,
          action: action_str,
          fidelity: ad.fidelity,
          provenance_source: get_in(ad.provenance, [:source])
        }
      )

      result
    else
      {:error, _} = err -> err
      {:error, _, _} = err -> err
    end
  end

  defp resolve(%ToolAd{} = ad), do: {:ok, ad}

  defp resolve(coordinate) when is_binary(coordinate) do
    case Discovery.find_one(ToolQuery.new(%{coordinate: coordinate})) do
      {:ok, ad} -> {:ok, ad}
      {:error, :not_found} = err -> err
    end
  end

  defp check_kind(%ToolAd{kinds: kinds}, kind) do
    if kind in kinds, do: :ok, else: {:error, :kind_not_supported}
  end

  defp resolve_adapter(%ToolAd{binding: {binding_kind, payload}}) do
    case Bindings.adapter_for(binding_kind) do
      {:ok, adapter} -> {:ok, adapter, payload}
      {:error, :not_found} -> {:error, :binding_not_supported}
    end
  end

  defp resolve_adapter(%ToolAd{binding: nil}), do: {:error, :binding_not_supported}

  defp action_to_string(s) when is_binary(s), do: s
  defp action_to_string(a) when is_atom(a), do: Atom.to_string(a)
  defp action_to_string(other), do: inspect(other)

  defp invoke(adapter, :query, payload, action, args, opts),
    do: adapter.query(payload, action, args, opts)

  defp invoke(adapter, :action, payload, action, args, opts) do
    key = Keyword.get(opts, :idempotency_key)
    adapter.act(payload, action, args, key, Keyword.delete(opts, :idempotency_key))
  end

  defp invoke(adapter, :stream, payload, action, args, opts) do
    subscriber = Keyword.fetch!(opts, :subscriber)
    adapter.subscribe(payload, action, args, subscriber, Keyword.delete(opts, :subscriber))
  end

  defp invoke(adapter, :compute, payload, action, args, opts),
    do: adapter.compute(payload, action, args, opts)

  defp invoke(adapter, :coordinate, payload, role, args, opts),
    do: adapter.participate(payload, role, args, opts)

  defp invoke(adapter, :spawn, payload, spec, _args, opts),
    do: adapter.spawn_child(payload, spec, opts)
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/llmagent/tool/dispatcher_test.exs`
Expected: 7 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/tool/dispatcher.ex test/llmagent/tool/dispatcher_test.exs
git commit -m "Add Tool Dispatcher with policy/kind/binding checks and telemetry"
```

---

## Task 14: Application supervision wiring + umbrella behaviour update

**Files:**
- Modify: `lib/tool.ex`
- Modify: `lib/llmagent/application.ex`
- Create: `test/llmagent/tool/substrate_boot_test.exs`

This task brings the substrate up under the application supervisor and adds the `ad/0` callback to the umbrella `LLMAgent.Tool` behaviour. Existing `describe/0`/`perform/2` callbacks become optional (deprecated).

- [ ] **Step 1: Read current application start sequence**

Read `lib/llmagent/application.ex` and locate the children list. Note where existing `init_registry/0` calls happen (likely for `LLMAgent.Tools`).

- [ ] **Step 2: Write the failing boot test**

```elixir
# test/llmagent/tool/substrate_boot_test.exs
defmodule LLMAgent.Tool.SubstrateBootTest do
  use ExUnit.Case, async: false

  test "Discovery is running under the application supervisor" do
    pid = Process.whereis(LLMAgent.Tools.Discovery)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "Kinds registry is seeded after boot" do
    assert :compute in LLMAgent.Tool.Kinds.list_kinds()
    assert :action in LLMAgent.Tool.Kinds.list_kinds()
  end

  test "Bindings registry has the :module adapter after boot" do
    assert {:ok, LLMAgent.Tool.Adapter.Module} =
             LLMAgent.Tool.Bindings.adapter_for(:module)
  end

  test "umbrella LLMAgent.Tool behaviour declares ad/0" do
    callbacks = LLMAgent.Tool.behaviour_info(:callbacks)
    assert {:ad, 0} in callbacks
  end

  test "describe/0 and perform/2 are optional callbacks" do
    optional = LLMAgent.Tool.behaviour_info(:optional_callbacks)
    assert {:describe, 0} in optional
    assert {:perform, 2} in optional
  end
end
```

- [ ] **Step 3: Run test to verify failure**

Run: `mix test test/llmagent/tool/substrate_boot_test.exs`
Expected: most tests fail (Discovery not running, registries not seeded, ad/0 not declared).

- [ ] **Step 4: Update `lib/tool.ex`**

```elixir
# lib/tool.ex
defmodule LLMAgent.Tool do
  @moduledoc """
  Umbrella behaviour for LLMAgent tools.

  New tools implement `ad/0` returning their authoritative `LLMAgent.ToolAd`,
  plus one or more kind behaviours from `LLMAgent.Tool.Kinds.*`.

  The legacy `describe/0` + `perform/2` callbacks remain optional and
  deprecated; they are kept until all existing tools have migrated. See
  the spec at `docs/superpowers/specs/2026-05-03-tool-discovery-design.md`
  for the migration plan.
  """

  @type tool_result ::
          {:ok, %{output: term(), metadata: map()}}
          | {:error, Comn.Errors.ErrorStruct.t()}

  @callback ad() :: LLMAgent.ToolAd.t()
  @callback describe() :: String.t()
  @callback perform(action :: String.t(), args :: map()) :: tool_result()

  @optional_callbacks ad: 0, describe: 0, perform: 2
end
```

Note: `ad/0` is optional during migration. After all tools have migrated and the legacy paths are removed (a future plan), `ad/0` becomes required and `describe/0`/`perform/2` are removed entirely.

- [ ] **Step 5: Update `lib/llmagent/application.ex`**

Two edits:

**Edit 1**: Add the two new registry seeds right after the existing `LLMAgent.Tools.init_registry()` line (line 9). Replace:

```elixir
    check_system_requirements()
    LLMAgent.Tools.init_registry()
```

with:

```elixir
    check_system_requirements()
    LLMAgent.Tools.init_registry()
    LLMAgent.Tool.Kinds.init_registry()
    LLMAgent.Tool.Bindings.init_registry()
```

**Edit 2**: Add `{LLMAgent.Tools.Discovery, []}` to the `children` list, after the `LLMAgent.TupleSpace.Supervisor` line (so the tuple space is up before Discovery starts polling for announcements). Replace:

```elixir
      {Registry, keys: :unique, name: LLMAgent.TupleSpace.Registry},
      {DynamicSupervisor, name: LLMAgent.TupleSpace.Supervisor, strategy: :one_for_one}
    ]
```

with:

```elixir
      {Registry, keys: :unique, name: LLMAgent.TupleSpace.Registry},
      {DynamicSupervisor, name: LLMAgent.TupleSpace.Supervisor, strategy: :one_for_one},
      {LLMAgent.Tools.Discovery, []}
    ]
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/llmagent/tool/substrate_boot_test.exs`
Expected: 5 tests, 0 failures.

- [ ] **Step 7: Run the full test suite to confirm nothing else regressed**

Run: `mix test`
Expected: all existing tests still pass; new tests added in this plan also pass.

- [ ] **Step 8: Commit**

```bash
git add lib/tool.ex lib/llmagent/application.ex test/llmagent/tool/substrate_boot_test.exs
git commit -m "Wire tool-discovery substrate into application supervisor

Adds ad/0 to LLMAgent.Tool umbrella behaviour (optional during migration).
Discovery GenServer starts under the application supervisor; Kinds and
Bindings registries are seeded at boot.

describe/0 and perform/2 are now optional callbacks; existing tools that
implement them continue to work unchanged."
```

---

## Self-Review Checklist

After completing all 14 tasks, run:

- [ ] `mix test` — full suite green.
- [ ] `mix compile --warnings-as-errors` — no warnings.
- [ ] Spot-check telemetry: write a one-off script that registers a stub ad, dispatches through it, and prints the emitted event.
- [ ] Verify the legacy `LLMAgent.Tools.get/1` API still works (no tools have been migrated yet, but the legacy table should still serve).

## What this plan deliberately doesn't do

- **No tool migrations.** Crypto, Bash, Web, etc. still use the legacy path. The first migration (Crypto) is a separate plan.
- **No agent dispatch path changes.** `LLMAgent.dispatch_tool/3` continues to use `LLMAgent.Tools.get/1`. The dispatch path migration is a separate plan.
- **No coexistence shim** in `LLMAgent.Tools.get/1`. Adding the shim is part of the first tool-migration plan, where it's actually needed.
- **No `:process`, `:remote`, `:http`, or `:mcp` adapters.** Each is added in the plan that migrates a tool needing it.
- **No DurableLog persistence**, **no signature verification**, **no liveness-by-binding eviction**, **no policy-as-ad**. All flagged as follow-on work in the spec.

## Follow-on plans

- **Plan #2: Crypto migration as proof-of-end-to-end.** Migrate `LLMAgent.Tools.Crypto` to the new path. Add the legacy coexistence shim to `LLMAgent.Tools.get/1`. Validate the full register → discover → dispatch flow with a real tool.
- **Plan #3-N: Per-tool migrations.** Net, Proc, Inotify/Udev (introduces `:process` adapter for streaming), File, Web (introduces `:http` adapter), Systemd, DBus, TupleSpace, Agent, Bash.
- **Plan: Agent dispatch path migration.** Switch `LLMAgent.dispatch_tool/3` to `LLMAgent.Tool.Dispatcher`. Update `allowed_tools` policy interpretation. Regenerate the LLM-facing tool catalog from ads.
- **Plan: Subtraction.** Remove `perform/2` shims, the `:persistent_term` legacy table, the legacy coordinate map, and the deprecated `describe/0` callback.

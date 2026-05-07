# mDNS LLM Endpoint Discovery — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make local llama.cpp servers advertised over `_llama._tcp` mDNS discoverable as `LLMAgent.ToolAd` records via a userspace Tcl shim that pipes EDN to a BEAM-side reader, and add the missing `:generate` kind plus an `:openai_chat` binding adapter so those ads are dispatchable end-to-end.

**Architecture:** The Tcl shim wraps `avahi-browse` and emits one EDN-encoded `:register` or `:expire` event per line on stdout. A supervised `LLMAgent.Discovery.PortAdapter` GenServer opens the shim as an Erlang Port, decodes each line via `eden`, and calls `LLMAgent.Tools.Discovery.{register,update,unregister}/1`. A new `:generate` kind (stochastic, retryable, not cacheable) carries chat completion semantics; an `:openai_chat` binding adapter implements it by delegating to the existing `LLMAgent.LLMClient.OpenAI`.

**Tech Stack:** Elixir/OTP (existing); Erlang Port for IPC; `eden` hex package for EDN parsing; Tcl 8.6 for the userspace shim; `avahi-utils` (`avahi-browse`) on the host.

**Spec:** `docs/superpowers/specs/2026-05-07-mdns-llm-discovery.md`.

---

## File Structure

**Created:**

- `lib/llmagent/tool/kinds/generate.ex` — `:generate` kind behaviour module
- `lib/llmagent/tool/adapter/openai_chat.ex` — binding adapter implementing `:generate`
- `lib/llmagent/discovery/wire.ex` — EDN encode/decode of register/expire events
- `lib/llmagent/discovery/port_adapter.ex` — supervised GenServer reading EDN from a port
- `lib/llmagent/discovery/adapter_supervisor.ex` — `DynamicSupervisor` for `PortAdapter` children
- `priv/discovery/avahi-llama.tcl` — Tcl shim for `_llama._tcp`
- `test/llmagent/tool/kinds/generate_test.exs`
- `test/llmagent/tool/adapter/openai_chat_test.exs`
- `test/llmagent/discovery/wire_test.exs`
- `test/llmagent/discovery/port_adapter_test.exs`
- `test/support/fake_shim.exs` — programmable fake shim used by `port_adapter_test`

**Modified:**

- `mix.exs` — add `{:eden, "~> 2.1"}` dependency
- `lib/llmagent/tool/kinds.ex:25-32` — add `:generate` to `@canonical`
- `lib/llmagent/tool/adapter.ex:108-112` — add `generate/4` callback + `@optional_callbacks` entry
- `lib/llmagent/tool/bindings.ex:28` — register `:openai_chat` binding kind
- `lib/llmagent/tool/dispatcher.ex` — add public `generate/4` and private `invoke(_, :generate, ...)` clause
- `lib/llmagent/application.ex` — start `Discovery.AdapterSupervisor`, launch configured shims
- `config/config.exs` (create if absent) — `discovery_adapters` entry

---

### Task 1: Add `eden` dependency

**Files:**

- Modify: `mix.exs:32-41`
- Test: `test/llmagent/discovery/wire_test.exs` (smoke only here)

- [ ] **Step 1: Add the dep**

Edit `mix.exs` `defp deps`:

```elixir
defp deps do
  [
    {:mix_test_watch, "~> 1.1", only: [:dev], runtime: false},
    {:plug, "~> 1.16", only: [:test]},
    {:req, "~> 0.5.0"},
    {:jason, "~> 1.4"},
    {:b58, "~> 1.0"},
    {:eden, "~> 2.1"},
    {:comn, github: "imsmith/comn", tag: "v0.4.0"}
  ]
end
```

- [ ] **Step 2: Fetch and verify**

Run: `mix deps.get && mix compile`
Expected: `eden` listed in fetched deps; clean compile.

- [ ] **Step 3: Smoke-test eden**

Run: `mix run -e 'IO.inspect(:eden.encode(%{a: 1}))'`
Expected: a binary string containing `{:a 1}` (exact format may vary; just confirm no exception).

- [ ] **Step 4: Commit**

```bash
git add mix.exs mix.lock
git commit -m "Add eden dependency for EDN wire format"
```

---

### Task 2: Add `:generate` kind behaviour

**Files:**

- Create: `lib/llmagent/tool/kinds/generate.ex`
- Test: `test/llmagent/tool/kinds/generate_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/llmagent/tool/kinds/generate_test.exs`:

```elixir
defmodule LLMAgent.Tool.Kinds.GenerateTest do
  use ExUnit.Case, async: true

  test "behaviour exposes generate/2 callback" do
    callbacks = LLMAgent.Tool.Kinds.Generate.behaviour_info(:callbacks)
    assert {:generate, 2} in callbacks
  end

  test "implementations satisfy the contract" do
    defmodule Echo do
      @behaviour LLMAgent.Tool.Kinds.Generate
      @impl true
      def generate("chat", %{messages: msgs}) do
        {:ok, "echo: " <> List.last(msgs)["content"], %{model: "echo"}}
      end
    end

    assert {:ok, "echo: hi", %{model: "echo"}} =
             Echo.generate("chat", %{messages: [%{"role" => "user", "content" => "hi"}]})
  end
end
```

- [ ] **Step 2: Run to confirm fail**

Run: `mix test test/llmagent/tool/kinds/generate_test.exs`
Expected: compile error on `LLMAgent.Tool.Kinds.Generate` (module not defined).

- [ ] **Step 3: Implement the behaviour**

Create `lib/llmagent/tool/kinds/generate.ex`:

```elixir
defmodule LLMAgent.Tool.Kinds.Generate do
  @moduledoc """
  The `:generate` kind. Stochastic, retryable, not cacheable.

  A `:generate` tool produces an output from a prompt where re-running with
  identical inputs may produce different outputs (LLM completion, image
  generation, etc.). The agent may retry safely, but must not cache results
  by input hash.

  Distinct from `:compute` (pure, deterministic) and `:query` (idempotent
  read). The result tuple carries an explicit `provenance` map for model id,
  latency, token counts, and any other observation that downstream consumers
  (trained-ad lifecycle, billing, fairness) may want to use.

  See `docs/superpowers/specs/2026-05-07-mdns-llm-discovery.md`.

  ## Minimal implementation

  ```elixir
  @behaviour LLMAgent.Tool.Kinds.Generate

  @impl true
  def generate("chat", %{messages: msgs}) do
    {:ok, "hello, world", %{model: "stub", latency_ms: 1}}
  end
  ```
  """

  @typedoc "Generated value. Implementation-defined shape (typically a string for chat)."
  @type value :: term()

  @typedoc """
  Per-call provenance: `:model`, `:latency_ms`, `:tokens_in`, `:tokens_out`,
  and any implementation-specific observations. Open map.
  """
  @type provenance :: map()

  @typedoc "Error reason. Any term."
  @type error_reason :: term()

  @typedoc "Result of a successful generation: `{:ok, value, provenance}`. On failure: `{:error, reason}`."
  @type result :: {:ok, value(), provenance()} | {:error, error_reason()}

  @doc "Produce a stochastic output. Retryable but not cacheable. Returns `{:ok, value, provenance}` on success or `{:error, reason}` on failure."
  @callback generate(action :: String.t(), args :: map()) :: result()
end
```

- [ ] **Step 4: Run to confirm pass**

Run: `mix test test/llmagent/tool/kinds/generate_test.exs`
Expected: 2 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/tool/kinds/generate.ex test/llmagent/tool/kinds/generate_test.exs
git commit -m "Add :generate kind behaviour for stochastic LLM completion"
```

---

### Task 3: Register `:generate` in the canonical kinds map

**Files:**

- Modify: `lib/llmagent/tool/kinds.ex:25-32`
- Test: extend existing `test/llmagent/tool/kinds_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/llmagent/tool/kinds_test.exs`:

```elixir
test ":generate is registered as a canonical kind" do
  LLMAgent.Tool.Kinds.init_registry()
  assert :generate in LLMAgent.Tool.Kinds.list_kinds()
  assert {:ok, LLMAgent.Tool.Kinds.Generate} =
           LLMAgent.Tool.Kinds.behaviour_for(:generate)
end
```

- [ ] **Step 2: Run to confirm fail**

Run: `mix test test/llmagent/tool/kinds_test.exs`
Expected: failure on `:generate` not in `list_kinds`.

- [ ] **Step 3: Add to canonical map**

Edit `lib/llmagent/tool/kinds.ex:25-32`:

```elixir
@canonical %{
  query:      LLMAgent.Tool.Kinds.Query,
  action:     LLMAgent.Tool.Kinds.Action,
  stream:     LLMAgent.Tool.Kinds.Stream,
  compute:    LLMAgent.Tool.Kinds.Compute,
  coordinate: LLMAgent.Tool.Kinds.Coordinate,
  spawn:      LLMAgent.Tool.Kinds.SpawnKind,
  generate:   LLMAgent.Tool.Kinds.Generate
}
```

Update the module's `@moduledoc` line that says "the six canonical kinds" to "the seven canonical kinds" and update the listed kinds.

- [ ] **Step 4: Run to confirm pass**

Run: `mix test`
Expected: all tests pass; the new test among them.

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/tool/kinds.ex test/llmagent/tool/kinds_test.exs
git commit -m "Register :generate in canonical kinds map"
```

---

### Task 4: Add `generate/4` callback to the Adapter behaviour

**Files:**

- Modify: `lib/llmagent/tool/adapter.ex` (insert before `@optional_callbacks` block)

- [ ] **Step 1: Write the failing test**

Append to `test/llmagent/tool/adapter_test.exs` (create if missing using `use ExUnit.Case, async: true`):

```elixir
test "Adapter behaviour declares generate/4 as optional" do
  callbacks = LLMAgent.Tool.Adapter.behaviour_info(:callbacks)
  assert {:generate, 4} in callbacks
  optional = LLMAgent.Tool.Adapter.behaviour_info(:optional_callbacks)
  assert {:generate, 4} in optional
end
```

- [ ] **Step 2: Run to confirm fail**

Run: `mix test test/llmagent/tool/adapter_test.exs`
Expected: failure on `{:generate, 4}` not in `:callbacks`.

- [ ] **Step 3: Add the callback**

In `lib/llmagent/tool/adapter.ex`, insert after the `compute/4` callback (around line 84) and before the `participate/4` callback:

```elixir
@doc "Produce a stochastic output. Retryable but not cacheable."
@callback generate(payload(), action :: String.t(), args :: map(),
                   opts :: keyword()) ::
            {:ok, value(), meta()} | {:error, error_reason()}
```

Update `@optional_callbacks` to include `generate: 4`:

```elixir
@optional_callbacks query: 4, act: 5, subscribe: 5, unsubscribe: 3, compute: 4,
                    generate: 4, participate: 4, leave: 3, spawn_child: 3,
                    child_status: 3, terminate_child: 4
```

- [ ] **Step 4: Run to confirm pass**

Run: `mix test test/llmagent/tool/adapter_test.exs`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/tool/adapter.ex test/llmagent/tool/adapter_test.exs
git commit -m "Add generate/4 callback to Tool.Adapter behaviour"
```

---

### Task 5: Wire `:generate` through the Dispatcher

**Files:**

- Modify: `lib/llmagent/tool/dispatcher.ex` (add public `generate/4`, private `invoke(_, :generate, ...)`)
- Test: extend `test/llmagent/tool/dispatcher_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/llmagent/tool/dispatcher_test.exs`:

```elixir
test "dispatches :generate via adapter.generate/4" do
  defmodule StubGen do
    @behaviour LLMAgent.Tool.Adapter
    @impl true
    def generate(payload, action, args, _opts) do
      {:ok, "answer for #{action}", %{model: payload.model}}
    end
  end

  :ok = LLMAgent.Tool.Bindings.register(:stub_gen, StubGen)

  ad = LLMAgent.ToolAd.new(%{
    id: "gen.test.1",
    coordinate: "compute.llm.chat",
    kinds: [:generate],
    binding: {:stub_gen, %{model: "stub-1"}},
    operational: %{actions: %{}},
    constraint: %{idempotency: %{}, blast_radius: %{}},
    affordance: %{declared: [], learned: [], open: false},
    fidelity: :authoritative,
    provenance: %{source: "test", produced_at: DateTime.utc_now(), based_on: [], signature: nil},
    lease: :permanent
  })

  :ok = LLMAgent.Tools.Discovery.update(ad)

  assert {:ok, "answer for chat", %{model: "stub-1"}} =
           LLMAgent.Tool.Dispatcher.generate(ad, "chat", %{messages: []})
end
```

- [ ] **Step 2: Run to confirm fail**

Run: `mix test test/llmagent/tool/dispatcher_test.exs`
Expected: `LLMAgent.Tool.Dispatcher.generate/3` undefined.

- [ ] **Step 3: Add Dispatcher API**

In `lib/llmagent/tool/dispatcher.ex` add the public function near the existing `compute/4`:

```elixir
@doc """
Produce a stochastic output via a generate-kind tool.

Dispatches via the `:generate` kind. The ad must declare `:generate` in its
`kinds` list and its binding adapter must implement `generate/4`.
"""
@spec generate(ToolAd.t() | String.t(), String.t(), map(), opts()) :: result()
def generate(ad_or_coord, action, args, opts \\ []),
  do: dispatch(ad_or_coord, :generate, action, args, opts)
```

And add the invoke clause near the existing `:compute` clause (after `compute/4`):

```elixir
defp invoke(adapter, :generate, payload, action, args, opts),
  do: adapter.generate(payload, action, args, opts)
```

- [ ] **Step 4: Run to confirm pass**

Run: `mix test test/llmagent/tool/dispatcher_test.exs`
Expected: all dispatcher tests pass including the new one.

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/tool/dispatcher.ex test/llmagent/tool/dispatcher_test.exs
git commit -m "Wire :generate kind through Tool.Dispatcher"
```

---

### Task 6: `:openai_chat` binding adapter

**Files:**

- Create: `lib/llmagent/tool/adapter/openai_chat.ex`
- Test: `test/llmagent/tool/adapter/openai_chat_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/llmagent/tool/adapter/openai_chat_test.exs`:

```elixir
defmodule LLMAgent.Tool.Adapter.OpenAIChatTest do
  use ExUnit.Case, async: false

  alias LLMAgent.Tool.Adapter.OpenAIChat

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, host: "http://localhost:#{bypass.port}"}
  end

  test "delegates chat to the OpenAI client and returns provenance", %{bypass: bypass, host: host} do
    Bypass.expect_once(bypass, "POST", "/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "stub-model"
      Plug.Conn.resp(conn, 200, ~s({"choices":[{"message":{"content":"hello back"}}]}))
    end)

    payload = %{api_host: host, model: "stub-model"}
    args    = %{messages: [%{"role" => "user", "content" => "hi"}]}

    assert {:ok, "hello back", %{model: "stub-model", latency_ms: latency}} =
             OpenAIChat.generate(payload, "chat", args, [])
    assert is_integer(latency) and latency >= 0
  end

  test "returns an error tuple on http failure", %{bypass: bypass, host: host} do
    Bypass.expect_once(bypass, "POST", "/chat/completions", fn conn ->
      Plug.Conn.resp(conn, 500, ~s({"error":"boom"}))
    end)

    payload = %{api_host: host, model: "stub-model"}
    args    = %{messages: [%{"role" => "user", "content" => "hi"}]}

    assert {:error, {:http_error, 500, _}} =
             OpenAIChat.generate(payload, "chat", args, [])
  end

  test "rejects unknown actions" do
    payload = %{api_host: "http://localhost:1", model: "stub"}
    assert {:error, :unknown_action} =
             OpenAIChat.generate(payload, "speak", %{}, [])
  end
end
```

If `Bypass` is not available in the project, add `{:bypass, "~> 2.1", only: :test}` to deps and re-run `mix deps.get`. Check first: `grep bypass mix.lock` — if no match, add it as part of this step.

- [ ] **Step 2: Run to confirm fail**

Run: `mix test test/llmagent/tool/adapter/openai_chat_test.exs`
Expected: compile error on `LLMAgent.Tool.Adapter.OpenAIChat`.

- [ ] **Step 3: Implement the adapter**

Create `lib/llmagent/tool/adapter/openai_chat.ex`:

```elixir
defmodule LLMAgent.Tool.Adapter.OpenAIChat do
  @moduledoc """
  Binding adapter that bridges the `:generate` kind to an OpenAI-compatible
  chat-completions HTTP endpoint by delegating to `LLMAgent.LLMClient.OpenAI`.

  Binding payload shape:

      %{api_host: "http://10.10.1.226:8080", model: "gemma-..."}

  The `:openai_chat` binding kind is registered at boot in
  `LLMAgent.Tool.Bindings.init_registry/0`.

  Supported actions: `"chat"`. Other actions return `{:error, :unknown_action}`.
  """

  @behaviour LLMAgent.Tool.Adapter

  alias LLMAgent.LLMClient.OpenAI

  @impl true
  def generate(%{api_host: host, model: model} = _payload, "chat", args, opts) do
    messages = Map.fetch!(args, :messages)
    timeout  = Keyword.get(opts, :timeout, 120_000)
    client   = %{api_host: host, model: model, timeout: timeout}

    started = System.monotonic_time(:millisecond)

    case OpenAI.chat(messages, client) do
      {:ok, content} ->
        latency = System.monotonic_time(:millisecond) - started
        {:ok, content, %{model: model, latency_ms: latency}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def generate(_payload, _action, _args, _opts), do: {:error, :unknown_action}
end
```

- [ ] **Step 4: Run to confirm pass**

Run: `mix test test/llmagent/tool/adapter/openai_chat_test.exs`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/tool/adapter/openai_chat.ex test/llmagent/tool/adapter/openai_chat_test.exs mix.exs mix.lock
git commit -m "Add :openai_chat binding adapter implementing :generate"
```

---

### Task 7: Register `:openai_chat` in the bindings map

**Files:**

- Modify: `lib/llmagent/tool/bindings.ex:28`
- Test: extend `test/llmagent/tool/bindings_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/llmagent/tool/bindings_test.exs`:

```elixir
test ":openai_chat is registered at boot" do
  LLMAgent.Tool.Bindings.init_registry()
  assert {:ok, LLMAgent.Tool.Adapter.OpenAIChat} =
           LLMAgent.Tool.Bindings.adapter_for(:openai_chat)
end
```

- [ ] **Step 2: Run to confirm fail**

Run: `mix test test/llmagent/tool/bindings_test.exs`
Expected: `{:error, :not_found}`.

- [ ] **Step 3: Add to canonical map**

Edit `lib/llmagent/tool/bindings.ex:28`:

```elixir
@canonical %{
  module: LLMAgent.Tool.Adapter.Module,
  openai_chat: LLMAgent.Tool.Adapter.OpenAIChat
}
```

- [ ] **Step 4: Run to confirm pass**

Run: `mix test test/llmagent/tool/bindings_test.exs`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/tool/bindings.ex test/llmagent/tool/bindings_test.exs
git commit -m "Register :openai_chat binding at boot"
```

---

### Task 8: EDN wire codec

**Files:**

- Create: `lib/llmagent/discovery/wire.ex`
- Test: `test/llmagent/discovery/wire_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/llmagent/discovery/wire_test.exs`:

```elixir
defmodule LLMAgent.Discovery.WireTest do
  use ExUnit.Case, async: true

  alias LLMAgent.Discovery.Wire
  alias LLMAgent.ToolAd

  defp sample_ad do
    ToolAd.new(%{
      id: "mdns:_llama._tcp:host:8080",
      coordinate: "compute.llm.chat",
      kinds: [:generate],
      binding: {:openai_chat, %{api_host: "http://10.0.0.1:8080", model: "m1"}},
      operational: %{actions: %{"chat" => %{concurrency: 4}}, model_id: "m1"},
      constraint:  %{idempotency: %{}, blast_radius: %{}},
      affordance:  %{declared: [%{intent: :long_context, n_ctx: 262_144}], learned: [], open: true},
      fidelity:    :authoritative,
      provenance:  %{source: "mdns/_llama._tcp", produced_at: ~U[2026-05-07 15:00:00Z], based_on: [], signature: nil},
      lease:       {:expires_at, ~U[2026-05-07 15:01:00Z]}
    })
  end

  test "decodes a register event into a ToolAd" do
    edn = ~s|{:event :register :ad {:id "x.1" :coordinate "compute.llm.chat" :kinds [:generate] :binding [:openai_chat {:api_host "http://h:8080" :model "m"}] :operational {:actions {} :model_id "m"} :constraint {:idempotency {} :blast_radius {}} :affordance {:declared [] :learned [] :open true} :fidelity :authoritative :provenance {:source "s" :produced_at "2026-05-07T15:00:00Z" :based_on [] :signature nil} :lease [:expires_at "2026-05-07T15:01:00Z"]}}|

    assert {:ok, {:register, %ToolAd{} = ad}} = Wire.decode(edn)
    assert ad.id == "x.1"
    assert ad.kinds == [:generate]
    assert {:openai_chat, %{api_host: "http://h:8080", model: "m"}} = ad.binding
    assert {:expires_at, %DateTime{}} = ad.lease
  end

  test "decodes an expire event" do
    edn = ~s|{:event :expire :id "x.1"}|
    assert {:ok, {:expire, "x.1"}} = Wire.decode(edn)
  end

  test "returns an error for malformed edn" do
    assert {:error, _} = Wire.decode("not valid edn")
  end

  test "returns an error for unknown event" do
    edn = ~s|{:event :poke :id "x"}|
    assert {:error, {:unknown_event, :poke}} = Wire.decode(edn)
  end

  test "encode/decode round-trips a sample ad" do
    ad = sample_ad()
    {:ok, line} = Wire.encode_register(ad)
    assert {:ok, {:register, decoded}} = Wire.decode(line)
    assert decoded.id == ad.id
    assert decoded.kinds == ad.kinds
    assert decoded.lease == ad.lease
  end
end
```

- [ ] **Step 2: Run to confirm fail**

Run: `mix test test/llmagent/discovery/wire_test.exs`
Expected: compile error on `LLMAgent.Discovery.Wire`.

- [ ] **Step 3: Implement the codec**

Create `lib/llmagent/discovery/wire.ex`:

```elixir
defmodule LLMAgent.Discovery.Wire do
  @moduledoc """
  EDN codec for the discovery wire protocol. Translates between EDN text
  lines emitted by discovery shims and `{event, payload}` tuples consumed by
  `LLMAgent.Discovery.PortAdapter`.

  Two events are supported:

  - `{:register, %LLMAgent.ToolAd{}}` — shim wants the registry to know about
    a tool. Adapter calls `Tools.Discovery.register/1` and falls back to
    `update/1` on `:duplicate_id`.
  - `{:expire, ad_id}` — shim observed the source go away. Adapter calls
    `Tools.Discovery.unregister/1`.

  The wire format is documented in
  `docs/superpowers/specs/2026-05-07-mdns-llm-discovery.md`.
  """

  alias LLMAgent.ToolAd

  @type event :: {:register, ToolAd.t()} | {:expire, binary()}

  @doc "Decode one EDN line into a `{event, payload}` tuple."
  @spec decode(binary()) :: {:ok, event()} | {:error, term()}
  def decode(line) when is_binary(line) do
    case safe_decode_edn(line) do
      {:ok, %{event: :register, ad: ad_map}} -> {:ok, {:register, to_ad(ad_map)}}
      {:ok, %{event: :expire, id: id}} when is_binary(id) -> {:ok, {:expire, id}}
      {:ok, %{event: other}} -> {:error, {:unknown_event, other}}
      {:ok, _} -> {:error, :malformed_event}
      {:error, _} = err -> err
    end
  end

  @doc "Encode a register event for a `%ToolAd{}` as one EDN line (used in tests and round-trips)."
  @spec encode_register(ToolAd.t()) :: {:ok, binary()}
  def encode_register(%ToolAd{} = ad) do
    payload = %{
      event: :register,
      ad: ad_to_map(ad)
    }
    {:ok, :eden.encode(payload)}
  end

  # --- private ---

  defp safe_decode_edn(line) do
    try do
      {:ok, :eden.decode(line)}
    rescue
      e -> {:error, e}
    catch
      :exit, reason -> {:error, reason}
      kind, reason  -> {:error, {kind, reason}}
    end
  end

  defp to_ad(%{} = m) do
    ToolAd.new(%{
      id:          Map.fetch!(m, :id),
      coordinate:  Map.fetch!(m, :coordinate),
      kinds:       Map.fetch!(m, :kinds),
      binding:     decode_binding(Map.fetch!(m, :binding)),
      operational: Map.fetch!(m, :operational),
      constraint:  Map.fetch!(m, :constraint),
      affordance:  Map.fetch!(m, :affordance),
      fidelity:    Map.fetch!(m, :fidelity),
      provenance:  decode_provenance(Map.fetch!(m, :provenance)),
      lease:       decode_lease(Map.fetch!(m, :lease))
    })
  end

  defp decode_binding([kind, payload]) when is_atom(kind), do: {kind, payload}
  defp decode_binding(other), do: other

  defp decode_provenance(%{produced_at: ts} = p) when is_binary(ts) do
    {:ok, dt, _} = DateTime.from_iso8601(ts)
    %{p | produced_at: dt}
  end
  defp decode_provenance(p), do: p

  defp decode_lease([:expires_at, ts]) when is_binary(ts) do
    {:ok, dt, _} = DateTime.from_iso8601(ts)
    {:expires_at, dt}
  end
  defp decode_lease(:permanent), do: :permanent
  defp decode_lease(other), do: other

  defp ad_to_map(%ToolAd{} = ad) do
    %{
      id:          ad.id,
      coordinate:  ad.coordinate,
      kinds:       ad.kinds,
      binding:     encode_binding(ad.binding),
      operational: ad.operational,
      constraint:  ad.constraint,
      affordance:  ad.affordance,
      fidelity:    ad.fidelity,
      provenance:  encode_provenance(ad.provenance),
      lease:       encode_lease(ad.lease)
    }
  end

  defp encode_binding({kind, payload}) when is_atom(kind), do: [kind, payload]
  defp encode_binding(other), do: other

  defp encode_provenance(%{produced_at: %DateTime{} = dt} = p),
    do: %{p | produced_at: DateTime.to_iso8601(dt)}
  defp encode_provenance(p), do: p

  defp encode_lease({:expires_at, %DateTime{} = dt}),
    do: [:expires_at, DateTime.to_iso8601(dt)]
  defp encode_lease(:permanent), do: :permanent
end
```

- [ ] **Step 4: Run to confirm pass**

Run: `mix test test/llmagent/discovery/wire_test.exs`
Expected: 5 tests pass.

If `:eden.decode/1` returns its data with binary keys instead of atom keys, adjust the `Map.fetch!` calls in `to_ad` and pattern match in `decode/1` to use `"event"` etc. — verify against the eden README and adjust the code (and the tests that reference atom keys) consistently.

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/discovery/wire.ex test/llmagent/discovery/wire_test.exs
git commit -m "Add EDN wire codec for discovery events"
```

---

### Task 9: Programmable fake shim for testing

**Files:**

- Create: `test/support/fake_shim.exs`

- [ ] **Step 1: Write the script**

Create `test/support/fake_shim.exs`:

```elixir
# Reads scripted commands from $LLMAGENT_FAKE_SHIM_SCRIPT (one per line)
# and writes them verbatim to stdout with a small delay between lines.
# Used by Discovery.PortAdapter tests to drive the GenServer with known input.
#
# Each line in the script file is either:
#   EMIT <edn-line>     — write the rest of the line to stdout
#   SLEEP <ms>          — wait
#   EXIT  <code>        — exit with the given status

path = System.get_env("LLMAGENT_FAKE_SHIM_SCRIPT") || raise "missing script"

path
|> File.stream!()
|> Stream.map(&String.trim_trailing/1)
|> Enum.each(fn
  "EMIT " <> rest ->
    IO.puts(rest)

  "SLEEP " <> ms ->
    ms |> String.to_integer() |> Process.sleep()

  "EXIT " <> code ->
    System.halt(String.to_integer(code))

  "" ->
    :ok

  other ->
    IO.puts(:stderr, "fake_shim: unknown directive: #{other}")
end)
```

- [ ] **Step 2: Smoke test it**

Run:

```bash
echo 'EMIT hello' > /tmp/shim.script
LLMAGENT_FAKE_SHIM_SCRIPT=/tmp/shim.script mix run test/support/fake_shim.exs
```

Expected: prints `hello` and exits 0.

- [ ] **Step 3: Commit**

```bash
git add test/support/fake_shim.exs
git commit -m "Add programmable fake shim for PortAdapter tests"
```

---

### Task 10: `Discovery.PortAdapter` GenServer

**Files:**

- Create: `lib/llmagent/discovery/port_adapter.ex`
- Test: `test/llmagent/discovery/port_adapter_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/llmagent/discovery/port_adapter_test.exs`:

```elixir
defmodule LLMAgent.Discovery.PortAdapterTest do
  use ExUnit.Case, async: false

  alias LLMAgent.Discovery.{PortAdapter, Wire}
  alias LLMAgent.Tools.Discovery, as: Reg

  setup do
    Reg.reset!()
    :ok
  end

  defp script_lines(ad) do
    {:ok, register_line} = Wire.encode_register(ad)
    [
      "EMIT " <> register_line,
      "SLEEP 50",
      "EMIT {:event :expire :id \"" <> ad.id <> "\"}",
      "SLEEP 50",
      "EXIT 0"
    ]
  end

  defp write_script(lines) do
    path = Path.join(System.tmp_dir!(), "shim_#{System.unique_integer([:positive])}.script")
    File.write!(path, Enum.join(lines, "\n") <> "\n")
    path
  end

  defp sample_ad(id \\ "test.adapter.1") do
    LLMAgent.ToolAd.new(%{
      id: id,
      coordinate: "compute.llm.chat",
      kinds: [:generate],
      binding: {:openai_chat, %{api_host: "http://h:8080", model: "m"}},
      operational: %{actions: %{}, model_id: "m"},
      constraint:  %{idempotency: %{}, blast_radius: %{}},
      affordance:  %{declared: [], learned: [], open: true},
      fidelity:    :authoritative,
      provenance:  %{source: "test", produced_at: DateTime.utc_now(), based_on: [], signature: nil},
      lease:       {:expires_at, DateTime.add(DateTime.utc_now(), 60)}
    })
  end

  test "registers ad on :register event and unregisters on :expire" do
    ad = sample_ad()
    script_path = write_script(script_lines(ad))

    {:ok, pid} = PortAdapter.start_link(
      name: :test_adapter,
      command: System.find_executable("elixir"),
      args: ["-r", "test/support/fake_shim.exs", "-e", ":timer.sleep(100)"],
      env: [{~c"LLMAGENT_FAKE_SHIM_SCRIPT", String.to_charlist(script_path)}]
    )

    Process.sleep(40)
    {:ok, [^ad]} = Reg.find_all(LLMAgent.ToolQuery.new(%{coordinate: "compute.llm.chat"}))

    Process.sleep(120)
    {:ok, []} = Reg.find_all(LLMAgent.ToolQuery.new(%{coordinate: "compute.llm.chat"}))

    GenServer.stop(pid)
  end

  test "skips malformed lines without crashing" do
    script_path = write_script([
      "EMIT not valid edn",
      "EMIT {:event :register :ad bogus}",
      "SLEEP 30",
      "EXIT 0"
    ])

    {:ok, pid} = PortAdapter.start_link(
      name: :test_adapter_2,
      command: System.find_executable("elixir"),
      args: ["-r", "test/support/fake_shim.exs", "-e", ":timer.sleep(100)"],
      env: [{~c"LLMAGENT_FAKE_SHIM_SCRIPT", String.to_charlist(script_path)}]
    )

    Process.sleep(80)
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end
end
```

Note: the elixir-driven invocation of `fake_shim.exs` is a workaround for not having a standalone shim script in CI. Real Tcl integration is in Task 13.

- [ ] **Step 2: Run to confirm fail**

Run: `mix test test/llmagent/discovery/port_adapter_test.exs`
Expected: compile error on `LLMAgent.Discovery.PortAdapter`.

- [ ] **Step 3: Implement the GenServer**

Create `lib/llmagent/discovery/port_adapter.ex`:

```elixir
defmodule LLMAgent.Discovery.PortAdapter do
  @moduledoc """
  Supervises an external discovery shim and translates its EDN-on-stdout
  output into `LLMAgent.Tools.Discovery` calls.

  Spawns the shim as an Erlang `Port` in `:line` mode. Each complete line is
  decoded with `LLMAgent.Discovery.Wire.decode/1`. Successful decodes drive
  the registry:

  - `{:register, ad}` → `Discovery.register/1`, falling back to `update/1` on
    `:duplicate_id`. This makes re-emit-on-shim-restart idempotent.
  - `{:expire, id}` → `Discovery.unregister/1`.

  Decode failures are logged and skipped — the adapter does not crash on
  malformed input. Port closure terminates the GenServer; the supervisor
  decides whether to restart.

  Configure via `start_link/1`:

      {LLMAgent.Discovery.PortAdapter,
        name: :avahi_llama,
        command: "/usr/bin/tclsh",
        args: ["priv/discovery/avahi-llama.tcl"],
        env: []}

  See `docs/superpowers/specs/2026-05-07-mdns-llm-discovery.md`.
  """

  use GenServer
  require Logger

  alias LLMAgent.Discovery.Wire
  alias LLMAgent.Tools.Discovery, as: Reg

  defstruct [:name, :port]

  @type opts :: [
          name: atom(),
          command: binary(),
          args: [binary()],
          env: [{charlist(), charlist()}]
        ]

  @doc "Start a PortAdapter under a supervisor. `:name` and `:command` are required."
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: process_name(name))
  end

  defp process_name(name), do: {:global, {__MODULE__, name}}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    cmd  = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    env  = Keyword.get(opts, :env, [])

    port = Port.open({:spawn_executable, cmd}, [
      :binary,
      :exit_status,
      {:line, 65_536},
      {:args, args},
      {:env, env}
    ])

    {:ok, %__MODULE__{name: Keyword.fetch!(opts, :name), port: port}}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    handle_line(line, state)
    {:noreply, state}
  end

  def handle_info({port, {:data, {:noeol, _}}}, %{port: port} = state) do
    Logger.warning("PortAdapter #{state.name}: shim emitted line over 64KiB; dropping")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("PortAdapter #{state.name}: shim exited with status #{status}")
    {:stop, {:shim_exit, status}, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp handle_line(line, state) do
    case Wire.decode(line) do
      {:ok, {:register, ad}} ->
        case Reg.register(ad) do
          :ok -> :ok
          {:error, :duplicate_id} -> Reg.update(ad)
          {:error, reason} ->
            Logger.warning("PortAdapter #{state.name}: register failed: #{inspect(reason)}")
        end

      {:ok, {:expire, id}} ->
        Reg.unregister(id)

      {:error, reason} ->
        Logger.warning("PortAdapter #{state.name}: decode failed: #{inspect(reason)} for line: #{inspect(line)}")
    end
  end

  @impl true
  def terminate(_reason, %{port: port}) do
    if is_port(port) and Port.info(port) != nil do
      Port.close(port)
    end
    :ok
  end
end
```

- [ ] **Step 4: Run to confirm pass**

Run: `mix test test/llmagent/discovery/port_adapter_test.exs`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/llmagent/discovery/port_adapter.ex test/llmagent/discovery/port_adapter_test.exs
git commit -m "Add Discovery.PortAdapter GenServer reading EDN from shim port"
```

---

### Task 11: Discovery adapter supervisor + application wiring

**Files:**

- Create: `lib/llmagent/discovery/adapter_supervisor.ex`
- Modify: `lib/llmagent/application.ex:20-39`
- Modify or create: `config/config.exs`
- Test: `test/llmagent/discovery/adapter_supervisor_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/llmagent/discovery/adapter_supervisor_test.exs`:

```elixir
defmodule LLMAgent.Discovery.AdapterSupervisorTest do
  use ExUnit.Case, async: false

  alias LLMAgent.Discovery.AdapterSupervisor

  test "starts configured adapters as children" do
    {:ok, sup} = AdapterSupervisor.start_link([])
    assert is_pid(sup)
    children = DynamicSupervisor.which_children(AdapterSupervisor)
    assert is_list(children)
    Process.exit(sup, :normal)
  end

  test "start_adapter/1 launches a PortAdapter as a child" do
    {:ok, _} = AdapterSupervisor.start_link([])

    spec = %{
      name: :sup_test_adapter,
      command: System.find_executable("true") || "/bin/true",
      args: [],
      env: []
    }

    {:ok, pid} = AdapterSupervisor.start_adapter(spec)
    assert Process.alive?(pid)
    DynamicSupervisor.terminate_child(AdapterSupervisor, pid)
  end
end
```

- [ ] **Step 2: Run to confirm fail**

Run: `mix test test/llmagent/discovery/adapter_supervisor_test.exs`
Expected: compile error.

- [ ] **Step 3: Implement the supervisor**

Create `lib/llmagent/discovery/adapter_supervisor.ex`:

```elixir
defmodule LLMAgent.Discovery.AdapterSupervisor do
  @moduledoc """
  `DynamicSupervisor` for `LLMAgent.Discovery.PortAdapter` children.

  At application boot, `LLMAgent.Application` reads the `:discovery_adapters`
  config list and calls `start_adapter/1` for each entry. The supervisor
  uses a `:one_for_one` restart strategy: a misbehaving shim can crash and
  restart without affecting the other discovery sources.
  """

  use DynamicSupervisor

  alias LLMAgent.Discovery.PortAdapter

  @doc "Start the supervisor, registered globally under this module name."
  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_arg) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Start a `PortAdapter` child from a config map."
  @spec start_adapter(map()) :: DynamicSupervisor.on_start_child()
  def start_adapter(%{name: _, command: _} = spec) do
    opts = spec |> Map.to_list()
    DynamicSupervisor.start_child(__MODULE__, {PortAdapter, opts})
  end
end
```

- [ ] **Step 4: Wire into application**

Edit `lib/llmagent/application.ex` `start/2`. Insert into `children` after `{LLMAgent.Tools.Discovery, []}`:

```elixir
{LLMAgent.Discovery.AdapterSupervisor, []}
```

After the supervisor starts (after `Supervisor.start_link/2`), iterate the configured adapters:

```elixir
{:ok, sup} = Supervisor.start_link(children, opts)

Enum.each(
  Application.get_env(:LLMAgent, :discovery_adapters, []),
  &LLMAgent.Discovery.AdapterSupervisor.start_adapter/1
)

LLMAgent.AgentSupervisor.start_agent(agent_opts)
LLMAgent.TupleSpace.start_space(:default)
{:ok, sup}
```

- [ ] **Step 5: Add config entry**

Create or edit `config/config.exs`:

```elixir
import Config

config :LLMAgent, :discovery_adapters, []

if File.exists?(Path.expand("./#{config_env()}.exs", __DIR__)) do
  import_config "#{config_env()}.exs"
end
```

The default empty list means: nothing runs unless configured. Operators add their shim:

```elixir
config :LLMAgent, :discovery_adapters, [
  %{
    name: :avahi_llama,
    command: "/usr/bin/tclsh",
    args: [Path.expand("priv/discovery/avahi-llama.tcl", File.cwd!())],
    env: []
  }
]
```

- [ ] **Step 6: Run all tests**

Run: `mix test`
Expected: all tests pass; new supervisor tests among them; no regressions.

- [ ] **Step 7: Commit**

```bash
git add lib/llmagent/discovery/adapter_supervisor.ex \
        lib/llmagent/application.ex \
        test/llmagent/discovery/adapter_supervisor_test.exs \
        config/config.exs
git commit -m "Wire Discovery.AdapterSupervisor into application boot"
```

---

### Task 12: Tcl shim for `_llama._tcp`

**Files:**

- Create: `priv/discovery/avahi-llama.tcl`

- [ ] **Step 1: Sketch the shim**

Create `priv/discovery/avahi-llama.tcl`:

```tcl
#!/usr/bin/env tclsh
#
# avahi-llama.tcl — discovery shim for _llama._tcp services.
#
# Wraps `avahi-browse -p -r _llama._tcp` and translates its parsable output
# into LLMAgent discovery EDN events on stdout.
#
# Output format: one EDN record per line, terminated by \n. Two events:
#   {:event :register :ad {...}}
#   {:event :expire  :id "..."}
#
# See docs/superpowers/specs/2026-05-07-mdns-llm-discovery.md.

package require Tcl 8.6

# In-memory map: instance-key -> ad-id, so we can emit :expire on goodbye
# records (which lack the resolved fields).
array set instances {}

proc instance_key {iface proto name type domain} {
    return "$iface|$proto|$name|$type|$domain"
}

proc ad_id {host port} {
    return "mdns:_llama._tcp:$host:$port"
}

proc parse_txt {fields} {
    set out [dict create]
    foreach kv $fields {
        set kv [string trim $kv "\""]
        if {[regexp {^([^=]+)=(.*)$} $kv -> k v]} {
            dict set out $k $v
        }
    }
    return $out
}

proc edn_str {s} {
    # Quote a string for EDN — escape backslashes and double-quotes.
    set s [string map {\\ \\\\ \" \\\"} $s]
    return "\"$s\""
}

proc emit_register {ad_id host addr port txt} {
    set model  [expr {[dict exists $txt model]  ? [dict get $txt model]  : ""}]
    set n_ctx  [expr {[dict exists $txt n_ctx]  ? [dict get $txt n_ctx]  : "0"}]
    set slots  [expr {[dict exists $txt slots]  ? [dict get $txt slots]  : "1"}]
    set api    [expr {[dict exists $txt api]    ? [dict get $txt api]    : ""}]
    set status [expr {[dict exists $txt status] ? [dict get $txt status] : "ok"}]

    if {$api ne "openai-compatible"} { return }
    if {$status ne "ok"} { return }

    set api_host "http://$addr:$port"
    set now      [clock format [clock seconds]    -format "%Y-%m-%dT%H:%M:%SZ" -gmt 1]
    set expires  [clock format [expr {[clock seconds] + 60}] -format "%Y-%m-%dT%H:%M:%SZ" -gmt 1]

    set ad "{:id [edn_str $ad_id]"
    append ad " :coordinate \"compute.llm.chat\""
    append ad " :kinds \[:generate\]"
    append ad " :binding \[:openai_chat {:api_host [edn_str $api_host] :model [edn_str $model]}\]"
    append ad " :operational {:actions {\"chat\" {:concurrency $slots}} :model_id [edn_str $model]}"
    append ad " :constraint  {:idempotency {} :blast_radius {}}"
    append ad " :affordance  {:declared \[{:intent :long_context :n_ctx $n_ctx}\] :learned \[\] :open true}"
    append ad " :fidelity    :authoritative"
    append ad " :provenance  {:source \"mdns/_llama._tcp\" :produced_at [edn_str $now] :based_on \[\] :signature nil}"
    append ad " :lease       \[:expires_at [edn_str $expires]\]"
    append ad "}"

    puts "{:event :register :ad $ad}"
    flush stdout
}

proc emit_expire {ad_id} {
    puts "{:event :expire :id [edn_str $ad_id]}"
    flush stdout
}

proc handle_line {line} {
    global instances
    set parts [split $line ";"]
    if {[llength $parts] < 6} { return }

    set kind [lindex $parts 0]
    set iface  [lindex $parts 1]
    set proto  [lindex $parts 2]
    set name   [lindex $parts 3]
    set type   [lindex $parts 4]
    set domain [lindex $parts 5]
    set key [instance_key $iface $proto $name $type $domain]

    switch -- $kind {
        "+"  {
            # New service. Wait for the matching "=" (resolved) line to register.
        }
        "=" {
            # Resolved record:
            # =;iface;proto;name;type;domain;hostname;address;port;txt0 txt1 ...
            if {[llength $parts] < 9} { return }
            set host [lindex $parts 6]
            set addr [lindex $parts 7]
            set port [lindex $parts 8]
            set txts [lrange $parts 9 end]
            set txt  [parse_txt $txts]
            set id   [ad_id $host $port]
            set instances($key) $id
            emit_register $id $host $addr $port $txt
        }
        "-" {
            if {[info exists instances($key)]} {
                emit_expire $instances($key)
                unset instances($key)
            }
        }
        default {}
    }
}

# Spawn avahi-browse as a child. -p parsable, -r resolve, no -t (long-running).
set browse "|avahi-browse -p -r _llama._tcp 2>@stderr"
set chan [open $browse r]
fconfigure $chan -buffering line

while {[gets $chan line] >= 0} {
    handle_line $line
}

close $chan
```

- [ ] **Step 2: Mark executable and lint**

Run:

```bash
chmod +x priv/discovery/avahi-llama.tcl
tclsh -c 'source priv/discovery/avahi-llama.tcl' 2>&1 || true
```

Expected: no syntax error. (It will block on stdin/avahi if avahi runs; abort with Ctrl-C — we just want syntax-OK.)

If `avahi-browse` is not installed locally, `tclsh priv/discovery/avahi-llama.tcl` will fail at `open`. That's fine for the syntax check; runtime testing is manual (Task 14).

- [ ] **Step 3: Commit**

```bash
git add priv/discovery/avahi-llama.tcl
git commit -m "Add avahi-llama.tcl discovery shim for _llama._tcp"
```

---

### Task 13: Manual end-to-end validation

**Files:** none (manual procedure)

This is a smoke procedure to run on a host with `avahi-utils` installed and at least one llama-server visible on the LAN.

- [ ] **Step 1: Install avahi-utils if absent**

```bash
which avahi-browse || sudo apt-get install -y avahi-utils
```

- [ ] **Step 2: Verify mDNS visibility independently**

Run: `avahi-browse -p -r -t _llama._tcp`
Expected: at least one `=` line for each visible llama-server, with the TXT records described in the spec.

- [ ] **Step 3: Add the shim to runtime config**

Edit `config/dev.exs` (create if needed):

```elixir
import Config

config :LLMAgent, :discovery_adapters, [
  %{
    name: :avahi_llama,
    command: System.find_executable("tclsh"),
    args: [Path.expand("priv/discovery/avahi-llama.tcl", File.cwd!())],
    env: []
  }
]
```

- [ ] **Step 4: Boot iex and inspect the registry**

Run:

```bash
iex -S mix
```

In the shell:

```elixir
LLMAgent.Tools.Discovery.find_all(LLMAgent.ToolQuery.new(%{coordinate: "compute.llm.chat"}))
```

Expected: one ad per visible llama-server, with `binding: {:openai_chat, %{api_host: ..., model: ...}}`.

- [ ] **Step 5: Dispatch a real call**

In the same shell:

```elixir
{:ok, [ad | _]} = LLMAgent.Tools.Discovery.find_all(LLMAgent.ToolQuery.new(%{coordinate: "compute.llm.chat"}))

LLMAgent.Tool.Dispatcher.generate(ad, "chat", %{messages: [%{"role" => "user", "content" => "say hi"}]})
```

Expected: `{:ok, "<some response>", %{model: "...", latency_ms: <int>}}`.

- [ ] **Step 6: Test eviction**

Stop one llama-server (or unplug its host). Within ~60s:

```elixir
LLMAgent.Tools.Discovery.find_all(LLMAgent.ToolQuery.new(%{coordinate: "compute.llm.chat"}))
```

Expected: that endpoint's ad is gone.

- [ ] **Step 7: Document the procedure**

If the manual smoke succeeds, append a `## Manual smoke validation` section to the spec at `docs/superpowers/specs/2026-05-07-mdns-llm-discovery.md` recording the date and any observations (e.g. concrete model names seen, latency range). No commit needed if no doc changes; otherwise:

```bash
git add docs/superpowers/specs/2026-05-07-mdns-llm-discovery.md
git commit -m "Record manual smoke validation results"
```

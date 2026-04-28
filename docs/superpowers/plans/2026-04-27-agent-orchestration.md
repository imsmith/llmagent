# Agent Orchestration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a TupleSpace tool and an Agent tool so a root agent can spawn one level of child agents, scope their tool access, and coordinate with them through the existing tuple space.

**Architecture:** Two new modules implementing `LLMAgent.Tool` (`LLMAgent.Tools.TupleSpace`, `LLMAgent.Tools.Agent`). The TupleSpace tool is a thin JSON-aware adapter over the existing `LLMAgent.TupleSpace` facade. The Agent tool drives `LLMAgent.AgentSupervisor` for lifecycle and uses the tuple space for sync result waiting and child→parent communication. Two new fields are added to the `LLMAgent` GenServer state — `parent` (atom | nil) and `allowed_tools` (`[atom]` | `:all`) — and three small modifications to `LLMAgent.ex` enforce the whitelist, complete child conversations into the tuple space, and monitor the parent for orphan handling.

**Tech Stack:** Elixir, ExUnit, ExUnit doctests, existing `LLMAgent.TupleSpace` (`out`, `in_`, `rd`, `_nowait` variants), `LLMAgent.AgentSupervisor`, `Comn.Errors.ErrorStruct`, `Comn.Contexts`.

---

## File Structure

**New:**

- `lib/tools/tuple_space.ex` — `LLMAgent.Tools.TupleSpace` — JSON adapter over `LLMAgent.TupleSpace`. Handles tuple/pattern encoding (JSON array ↔ Erlang tuple, `"_"` ↔ `:_`).
- `lib/tools/agent.ex` — `LLMAgent.Tools.Agent` — Lifecycle only: `spawn` (sync/async), `kill`, `list`, `status`. Reads caller identity from `Comn.Contexts` to enforce spawn depth.
- `test/tools/tuple_space_tool_test.exs` — Unit tests for the TupleSpace tool's `perform/2`.
- `test/tools/agent_tool_test.exs` — Unit tests for the Agent tool's `perform/2`.
- `test/agent_orchestration_test.exs` — Integration tests covering sync/async spawn, orphan, crash, whitelist, and depth-enforcement scenarios.

**Modified:**

- `lib/LLMAgent.ex` — add `parent` and `allowed_tools` to state from opts; expose them via Contexts; whitelist check in `timed_dispatch`; child completion path writes `{:agent_result, name, content}` and self-terminates; `terminate/2` writes `{:agent_error, name, reason}` for abnormal exits when `parent != nil`; monitor parent process for orphan event.
- `lib/tools.ex` — add `:tuple_space` and `:agent` to `@builtins` and add `tuple_space/0` and `agent/0` convenience functions; update doctest expectations.

**Unchanged:**

- `lib/llmagent/tuple_space/*.ex` — used through public API only.
- `lib/llmagent/agent_supervisor.ex` — already supports dynamic spawn/stop with opts.
- `lib/llmagent/application.ex` — no new processes; tools register at boot via `init_registry/0`.
- `lib/event_bus.ex`, `lib/event_log.ex`, `lib/llmagent/durable_log.ex`, `lib/llmagent/memory.ex`, `lib/llmagent/llm_client.ex`.

---

## Conventions Used Across Tasks

- **Tuple/pattern encoding.** A JSON array `["task", "worker", "do thing"]` becomes the Erlang tuple `{"task", "worker", "do thing"}` — strings stay as strings. The single string `"_"` is the only special case: it becomes the wildcard atom `:_`. This avoids atom-table exhaustion from arbitrary LLM input. The orchestrator system prompt (out of scope for this plan) is what teaches the LLM to use this convention.
- **Caller identity.** The Agent tool needs to know who is spawning. We pipe `agent_name` and `agent_parent` through `Comn.Contexts` from `do_prompt/2` (alongside the existing `:role`, `:model` puts), and the Agent tool reads them from Contexts in `perform/2`. This avoids changing the `Tool` behaviour signature.
- **Sync result waiting.** A sync spawn writes to and reads from the `:default` tuple space using a unique-per-spawn correlation tag, e.g. `{:agent_result, name, _}`. The child's completion path always writes that tuple regardless of mode.
- **Tests.** Tests use `:global` registration (via `LLMAgent.start_link(name: ...)`), short timeouts, and `on_exit` cleanup. Unique agent/space names per test (`String.to_atom("foo_" <> Integer.to_string(System.unique_integer([:positive])))`) so tests can run with `async: false` without colliding when re-run.

---

## Task 1: Add `parent` and `allowed_tools` to LLMAgent state

**Files:**
- Modify: `lib/LLMAgent.ex` (init/1, state map)
- Modify: `lib/LLMAgent.ex` (do_prompt/2 — Contexts puts)
- Test: `test/agent_lifecycle_test.exs` (add new describe block at end)

This task is purely additive. No tool dispatch changes yet — those come in Task 2.

- [ ] **Step 1: Write the failing tests**

Append to `test/agent_lifecycle_test.exs` before the closing `end`:

```elixir
  # --- Orchestration state ---

  describe "orchestration state fields" do
    test "default state has parent=nil and allowed_tools=:all" do
      _pid = start_agent(:orch_default)
      state = get_state(:orch_default)
      assert state.parent == nil
      assert state.allowed_tools == :all
    end

    test "parent and allowed_tools can be set via opts" do
      _pid = start_agent(:orch_child, parent: :some_parent, allowed_tools: [:bash, :file])
      state = get_state(:orch_child)
      assert state.parent == :some_parent
      assert state.allowed_tools == [:bash, :file]
    end

    test "agent_name and agent_parent are placed in Contexts on prompt" do
      alias Comn.Contexts
      pid = start_agent(:orch_ctx, parent: :p_a)
      LLMAgent.prompt({:global, :orch_ctx}, "x")
      # Wait for the GenServer to have processed the prompt and updated Contexts
      Process.sleep(20)
      ctx = :sys.get_state(pid)
      assert ctx.parent == :p_a
      # Contexts is process-local; we verified state directly. We exercise the
      # Contexts piping in Agent-tool unit tests where we run perform/2 in the
      # caller process.
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/agent_lifecycle_test.exs --only orchestration_state`

Expected: FAIL — `state.parent` is undefined (KeyError) and `state.allowed_tools` likewise.

(If the `--only` tag does not match because we did not tag the describe block, run the full test file: `mix test test/agent_lifecycle_test.exs`. The new tests will fail; the rest will pass.)

- [ ] **Step 3: Add the fields to state**

In `lib/LLMAgent.ex`, modify `init/1` (currently lines ~28-59) to read the two new opts and add them to the state map:

```elixir
  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    role = Keyword.get(opts, :role, :default)
    memory = Keyword.get(opts, :memory, LLMAgent.Memory.ETS)
    llm_client = Keyword.get(opts, :llm_client, LLMAgent.LLMClient.OpenAI)
    parent = Keyword.get(opts, :parent, nil)
    allowed_tools = Keyword.get(opts, :allowed_tools, :all)

    memory.init(name)

    {history, restored?} = restore_history(name, role, memory)

    state = %{
      name: name,
      role: role,
      model: Keyword.get(opts, :model, @default_model),
      api_host: Keyword.get(opts, :api_host, @default_api_host),
      llm_client: llm_client,
      memory: memory,
      history: history,
      parent: parent,
      allowed_tools: allowed_tools
    }

    unless restored? do
      Events.emit(:message, "agent.message", %{
        agent_id: name,
        role: "system",
        content: hd(history).content
      }, __MODULE__)
    end

    memory.store(name, :history, state.history)

    {:ok, state}
  end
```

- [ ] **Step 4: Pipe caller identity through Contexts**

In `lib/LLMAgent.ex`, modify `do_prompt/2` (currently lines ~139-162) to also place `agent_name` and `agent_parent` into Contexts so tools running inside this GenServer can read them:

```elixir
  defp do_prompt(user_input, state) do
    request_id = "req_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    trace_id = state[:trace_id] || "trace_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    Contexts.new(%{
      request_id: request_id,
      trace_id: trace_id,
      actor: "agent"
    })
    Contexts.put(:role, state.role)
    Contexts.put(:model, state.model)
    Contexts.put(:agent_name, state.name)
    Contexts.put(:agent_parent, state.parent)

    Events.emit(:prompt, "agent.prompt", %{content: user_input, role: state.role}, __MODULE__)

    updated = append_message(state, "user", user_input)

    client_opts = %{api_host: updated.api_host, model: updated.model, timeout: 120_000}

    Task.Supervisor.async(LLMAgent.TaskSup, fn ->
      updated.llm_client.chat(updated.history, client_opts)
    end)

    updated
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/agent_lifecycle_test.exs`

Expected: All tests pass, including the three new ones.

- [ ] **Step 6: Commit**

```bash
git add lib/LLMAgent.ex test/agent_lifecycle_test.exs
git commit -m "Add parent + allowed_tools fields to LLMAgent state"
```

---

## Task 2: Enforce `allowed_tools` whitelist in `timed_dispatch`

**Files:**
- Modify: `lib/LLMAgent.ex` (timed_dispatch/3 → take state and check whitelist; or wrap dispatch_tool)
- Test: `test/agent_lifecycle_test.exs` (new describe block)

The simplest place to enforce is `dispatch_tool/3`. We change `timed_dispatch/3` to receive the state's `allowed_tools` and pass through, or — cleaner — change `handle_info/2` to call a new `timed_dispatch/4` that takes state.allowed_tools.

- [ ] **Step 1: Write the failing test**

Append to `test/agent_lifecycle_test.exs`:

```elixir
  describe "tool whitelist enforcement" do
    test "tool not in whitelist returns error without dispatching" do
      pid = start_agent(:wl_block, allowed_tools: [:file])

      simulate_llm_response(pid, tool_json("bash", "exec", %{"command" => "echo nope"}))
      Process.sleep(50)

      state = get_state(:wl_block)
      function_msg = Enum.find(state.history, &(&1.role == "function"))
      assert function_msg != nil
      assert function_msg.content =~ "tool :bash not permitted"
    end

    test "tool in whitelist dispatches normally" do
      pid = start_agent(:wl_allow, allowed_tools: [:bash])

      simulate_llm_response(pid, tool_json("bash", "exec", %{"command" => "echo allowed"}))
      Process.sleep(50)

      state = get_state(:wl_allow)
      function_msg = Enum.find(state.history, &(&1.role == "function"))
      assert function_msg.content =~ "allowed"
    end

    test ":all whitelist permits any tool (default)" do
      pid = start_agent(:wl_all)

      simulate_llm_response(pid, tool_json("bash", "exec", %{"command" => "echo any"}))
      Process.sleep(50)

      state = get_state(:wl_all)
      function_msg = Enum.find(state.history, &(&1.role == "function"))
      assert function_msg.content =~ "any"
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/agent_lifecycle_test.exs`

Expected: First test fails (bash dispatches and writes "nope" output instead of error). Other two pass already.

- [ ] **Step 3: Add whitelist enforcement**

In `lib/LLMAgent.ex`, modify the `handle_info({ref, {:ok, content}}, state)` clause (currently lines ~81-108). Change the `timed_dispatch(tool, action, args)` call to pass `state.allowed_tools`:

Replace:

```elixir
        result = timed_dispatch(tool, action, args)
```

with:

```elixir
        result = timed_dispatch(tool, action, args, state.allowed_tools)
```

Then change the `timed_dispatch/3` private function (currently lines ~166-189) to `timed_dispatch/4`, and add a guard that short-circuits to `{:error, ...}` if the tool is not allowed:

```elixir
  defp timed_dispatch(tool, action, args, allowed) do
    Contexts.put(:tool, tool)
    Contexts.put(:action, action)

    start = System.monotonic_time(:millisecond)

    result =
      if tool_allowed?(tool, allowed) do
        dispatch_tool(tool, action, args)
      else
        {:error,
         ErrorStruct.new("tool_not_permitted", "tool",
           "tool :#{tool} not permitted", "Use one of the allowed tools")}
      end

    duration_ms = System.monotonic_time(:millisecond) - start

    {result_status, _} = case result do
      {:ok, _} -> {:ok, nil}
      {:error, _} -> {:error, nil}
    end

    Events.emit(:invocation, "tool.#{tool}", %{
      action: action,
      args: sanitize_args(args),
      result: result_status,
      duration_ms: duration_ms
    }, __MODULE__)

    result
  end

  defp tool_allowed?(_tool, :all), do: true
  defp tool_allowed?(tool, allowed) when is_list(allowed), do: tool in allowed
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/agent_lifecycle_test.exs`

Expected: All tests pass.

- [ ] **Step 5: Run the whole suite to catch any regressions**

Run: `mix test`

Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/LLMAgent.ex test/agent_lifecycle_test.exs
git commit -m "Enforce allowed_tools whitelist in tool dispatch"
```

---

## Task 3: Child agents write result to tuple space and self-terminate on completion

**Files:**
- Modify: `lib/LLMAgent.ex` (the `:not_a_tool_call` branch in `handle_info`)
- Test: `test/agent_lifecycle_test.exs`

When the child's LLM produces a non-tool-call response and `state.parent != nil`, write `{:agent_result, name, content}` to the `:default` tuple space and ask `AgentSupervisor` to stop us. Root agents (`parent == nil`) keep the existing behavior.

- [ ] **Step 1: Write the failing test**

Append to `test/agent_lifecycle_test.exs`:

```elixir
  describe "child completion writes to tuple space" do
    setup do
      # Ensure the :default space is fresh for these tests
      LLMAgent.TupleSpace.stop_space(:default)
      {:ok, _} = LLMAgent.TupleSpace.start_space(:default)
      :ok
    end

    test "child writes {:agent_result, name, content} on non-tool response" do
      pid = start_agent(:child_complete, parent: :some_parent)

      simulate_llm_response(pid, "the answer is 42")
      Process.sleep(80)

      assert {:ok, {:agent_result, :child_complete, "the answer is 42"}} =
               LLMAgent.TupleSpace.in_nowait({:agent_result, :child_complete, :_})

      # Child should have stopped itself
      refute Process.alive?(pid)
    end

    test "root agent does not write to tuple space and stays alive" do
      pid = start_agent(:root_complete)

      simulate_llm_response(pid, "I am root, I keep going")
      Process.sleep(80)

      assert {:error, :no_match} =
               LLMAgent.TupleSpace.in_nowait({:agent_result, :root_complete, :_})
      assert Process.alive?(pid)
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/agent_lifecycle_test.exs`

Expected: First new test fails — no tuple is written; child stays alive.

- [ ] **Step 3: Implement child completion path**

In `lib/LLMAgent.ex`, modify the `:not_a_tool_call` branch in `handle_info({ref, {:ok, content}}, state)` (currently lines ~104-107) to dispatch on `state.parent`:

```elixir
      :not_a_tool_call ->
        updated = append_message(state, "assistant", content)

        case updated.parent do
          nil ->
            {:noreply, updated}

          _parent ->
            LLMAgent.TupleSpace.out({:agent_result, updated.name, content})
            # Schedule self-termination after we return so terminate/2 fires cleanly
            send(self(), :child_complete_stop)
            {:noreply, updated}
        end
    end
  end
```

Add a new `handle_info` clause (place it adjacent to the other `handle_info` clauses, near line ~127):

```elixir
  def handle_info(:child_complete_stop, state) do
    LLMAgent.AgentSupervisor.stop_agent(state.name)
    {:noreply, state}
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/agent_lifecycle_test.exs`

Expected: All tests pass.

- [ ] **Step 5: Run full suite**

Run: `mix test`

Expected: All pass. (The existing `loop terminates when LLM gives non-tool response` test should still pass because that agent has `parent == nil`.)

- [ ] **Step 6: Commit**

```bash
git add lib/LLMAgent.ex test/agent_lifecycle_test.exs
git commit -m "Children write result to tuple space and self-terminate"
```

---

## Task 4: Children write `{:agent_error, name, reason}` on abnormal exit

**Files:**
- Modify: `lib/LLMAgent.ex` (`terminate/2`)
- Test: `test/agent_lifecycle_test.exs`

Existing `terminate/2` only persists history. Extend it: if `state.parent != nil` and reason is not `:normal`/`:shutdown`, also write an error tuple.

- [ ] **Step 1: Write the failing test**

Append to `test/agent_lifecycle_test.exs`:

```elixir
  describe "child crash error tuple" do
    setup do
      LLMAgent.TupleSpace.stop_space(:default)
      {:ok, _} = LLMAgent.TupleSpace.start_space(:default)
      :ok
    end

    test "abnormal child exit writes {:agent_error, name, reason}" do
      pid = start_agent(:child_crash, parent: :some_parent)

      Process.flag(:trap_exit, true)
      Process.exit(pid, :killed_for_test)
      Process.sleep(80)

      # :killed gets translated to a reason tuple by OTP — accept any non-normal reason
      assert {:ok, {:agent_error, :child_crash, _reason}} =
               LLMAgent.TupleSpace.in_nowait({:agent_error, :child_crash, :_})
    end

    test "normal child exit does not write {:agent_error, ...}" do
      _pid = start_agent(:child_normal, parent: :some_parent)
      simulate_llm_response(:global |> then(fn _ -> GenServer.whereis({:global, :child_normal}) end), "done")
      Process.sleep(80)

      # Result tuple is present, error tuple is not
      assert {:ok, _} = LLMAgent.TupleSpace.in_nowait({:agent_result, :child_normal, :_})
      assert {:error, :no_match} = LLMAgent.TupleSpace.in_nowait({:agent_error, :child_normal, :_})
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/agent_lifecycle_test.exs`

Expected: First test fails (no tuple). Second may pass already.

- [ ] **Step 3: Extend terminate/2**

In `lib/LLMAgent.ex`, replace `terminate/2` (currently lines ~131-135) with:

```elixir
  @impl true
  def terminate(reason, state) do
    state.memory.store(state.name, :history, state.history)

    if state.parent != nil and reason not in [:normal, :shutdown] do
      try do
        LLMAgent.TupleSpace.out({:agent_error, state.name, inspect(reason)})
      catch
        _, _ -> :ok
      end
    end

    :ok
  end
```

The `inspect/1` keeps the reason simple-typed for the tuple space. The `try/catch` makes terminate robust if the tuple space is itself going down.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/agent_lifecycle_test.exs`

Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add lib/LLMAgent.ex test/agent_lifecycle_test.exs
git commit -m "Children write {:agent_error, ...} on abnormal exit"
```

---

## Task 5: Children monitor parent and emit `agent.orphaned` event on parent death

**Files:**
- Modify: `lib/LLMAgent.ex` (init/1 — monitor parent; handle_info `:DOWN` clause for the parent ref)
- Test: `test/agent_lifecycle_test.exs`

The child stores the monitor ref under `state.parent_ref` and continues running on `:DOWN`. On orphan, emit `agent.orphaned` and clear the ref.

- [ ] **Step 1: Write the failing test**

Append to `test/agent_lifecycle_test.exs`:

```elixir
  describe "orphan handling" do
    test "child emits agent.orphaned when parent dies and continues running" do
      LLMAgent.EventBus.subscribe("agent.orphaned")

      parent_name = :orph_parent
      child_name = :orph_child

      _parent_pid = start_agent(parent_name)
      child_pid = start_agent(child_name, parent: parent_name)

      assert Process.alive?(child_pid)

      GenServer.stop({:global, parent_name})
      Process.sleep(50)

      assert_receive {:event, "agent.orphaned", %Comn.Events.EventStruct{} = evt}, 1_000
      assert evt.data.agent_id == :orph_child
      assert evt.data.parent == :orph_parent

      # Child still running
      assert Process.alive?(child_pid)
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/agent_lifecycle_test.exs`

Expected: Fails — no event emitted, the existing generic `:DOWN` handler swallows it.

- [ ] **Step 3: Set up parent monitor in init**

In `lib/LLMAgent.ex` `init/1`, after `parent = Keyword.get(...)` add a monitor when parent is non-nil. Add `parent_ref` to the state map:

```elixir
    parent = Keyword.get(opts, :parent, nil)
    allowed_tools = Keyword.get(opts, :allowed_tools, :all)

    parent_ref =
      case parent do
        nil -> nil
        parent_name ->
          case GenServer.whereis({:global, parent_name}) do
            nil -> nil
            pid -> Process.monitor(pid)
          end
      end
```

Add to the state map:

```elixir
      parent: parent,
      parent_ref: parent_ref,
      allowed_tools: allowed_tools
```

- [ ] **Step 4: Handle the parent's :DOWN message**

In `lib/LLMAgent.ex`, replace the existing catch-all `:DOWN` clause (currently lines ~127-129) with two clauses — first the orphan-specific match, then the catch-all:

```elixir
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{parent_ref: ref} = state) do
    Events.emit(:orphaned, "agent.orphaned", %{
      agent_id: state.name,
      parent: state.parent
    }, __MODULE__)

    {:noreply, %{state | parent_ref: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end
```

- [ ] **Step 5: Make sure `Events.emit/4` supports the new event type**

Run: `grep -n "@type\|event_type\|@event" lib/llmagent/events.ex | head -30`

If the event type list is closed (e.g., a typespec), add `:orphaned`. If it is permissive (any atom), no change is needed.

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/agent_lifecycle_test.exs`

Expected: All pass.

- [ ] **Step 7: Commit**

```bash
git add lib/LLMAgent.ex test/agent_lifecycle_test.exs lib/llmagent/events.ex
git commit -m "Children monitor parent and emit agent.orphaned event"
```

---

## Task 6: Implement the TupleSpace tool

**Files:**
- Create: `lib/tools/tuple_space.ex`
- Test: `test/tools/tuple_space_tool_test.exs`

The tool is a JSON-aware adapter over `LLMAgent.TupleSpace`. JSON arrays ↔ Erlang tuples; the string `"_"` ↔ atom `:_`. All other strings stay as strings.

- [ ] **Step 1: Write the failing tests**

Create `test/tools/tuple_space_tool_test.exs`:

```elixir
defmodule LLMAgent.Tools.TupleSpaceTest do
  use ExUnit.Case, async: false

  alias LLMAgent.Tools.TupleSpace, as: TS
  alias LLMAgent.TupleSpace
  alias Comn.Errors.ErrorStruct

  setup do
    TupleSpace.stop_space(:default)
    {:ok, _} = TupleSpace.start_space(:default)
    :ok
  end

  describe "describe/0" do
    test "returns a string mentioning the actions" do
      desc = TS.describe()
      assert is_binary(desc)
      for a <- ~w(write read take read_nowait take_nowait list_spaces create_space destroy_space) do
        assert desc =~ a, "describe missing #{a}"
      end
    end
  end

  describe "perform/2 — write and read_nowait" do
    test "write encodes JSON array to tuple; read_nowait decodes back" do
      assert {:ok, %{output: "ok"}} =
               TS.perform("write", %{"space" => "default", "tuple" => ["greeting", "hi"]})

      assert {:ok, %{output: ["greeting", "hi"]}} =
               TS.perform("read_nowait", %{"space" => "default", "pattern" => ["greeting", "_"]})
    end

    test "read_nowait returns error tuple when no match" do
      assert {:error, %ErrorStruct{reason: "no_match"}} =
               TS.perform("read_nowait", %{"space" => "default", "pattern" => ["nope", "_"]})
    end
  end

  describe "perform/2 — take and take_nowait" do
    test "take_nowait removes the tuple" do
      :ok = TupleSpace.out({"task", "do it"})
      assert {:ok, %{output: ["task", "do it"]}} =
               TS.perform("take_nowait", %{"space" => "default", "pattern" => ["task", "_"]})
      assert {:error, %ErrorStruct{reason: "no_match"}} =
               TS.perform("take_nowait", %{"space" => "default", "pattern" => ["task", "_"]})
    end

    test "take with timeout blocks until match" do
      Task.start(fn ->
        Process.sleep(40)
        TupleSpace.out({"delayed", "yes"})
      end)

      assert {:ok, %{output: ["delayed", "yes"]}} =
               TS.perform("take", %{
                 "space" => "default",
                 "pattern" => ["delayed", "_"],
                 "timeout" => 1_000
               })
    end

    test "take with timeout returns timeout error" do
      assert {:error, %ErrorStruct{reason: "timeout"}} =
               TS.perform("take", %{
                 "space" => "default",
                 "pattern" => ["nope", "_"],
                 "timeout" => 50
               })
    end
  end

  describe "perform/2 — read with timeout" do
    test "non-destructive blocking read" do
      :ok = TupleSpace.out({"peek", "v"})
      assert {:ok, %{output: ["peek", "v"]}} =
               TS.perform("read", %{
                 "space" => "default",
                 "pattern" => ["peek", "_"],
                 "timeout" => 500
               })
      # Still there
      assert {:ok, %{output: ["peek", "v"]}} =
               TS.perform("read_nowait", %{"space" => "default", "pattern" => ["peek", "_"]})
    end
  end

  describe "perform/2 — space management" do
    test "create_space, list_spaces, destroy_space" do
      assert {:ok, %{output: "ok"}} = TS.perform("create_space", %{"name" => "ts_tool_named"})
      {:ok, %{output: spaces}} = TS.perform("list_spaces", %{})
      assert "ts_tool_named" in spaces
      assert {:ok, %{output: "ok"}} = TS.perform("destroy_space", %{"name" => "ts_tool_named"})
    end

    test "destroy_space on missing returns error" do
      assert {:error, %ErrorStruct{reason: "not_found"}} =
               TS.perform("destroy_space", %{"name" => "missing_ts_xyz"})
    end
  end

  describe "perform/2 — unknown action" do
    test "returns unknown_command" do
      assert {:error, %ErrorStruct{reason: "unknown_command"}} = TS.perform("nope", %{})
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/tools/tuple_space_tool_test.exs`

Expected: All fail — module does not exist.

- [ ] **Step 3: Implement the tool**

Create `lib/tools/tuple_space.ex`:

```elixir
defmodule LLMAgent.Tools.TupleSpace do
  @moduledoc """
  JSON-aware adapter over `LLMAgent.TupleSpace`.

  Tuples and patterns arrive as JSON arrays from the LLM and are converted to
  Erlang tuples. The string `"_"` in a pattern is mapped to the atom `:_`
  (wildcard). Results are converted back to JSON-friendly lists on egress.
  """

  @behaviour LLMAgent.Tool
  alias LLMAgent.TupleSpace, as: TS
  alias Comn.Errors.ErrorStruct

  @impl true
  def describe do
    """
    Coordination via Linda-style tuple spaces. Tuples and patterns are JSON arrays.
    Use the string "_" inside a pattern as a wildcard.

    Actions:
      - write {space, tuple}: write a tuple. Returns "ok".
        Example: {"tool":"tuple_space","action":"write","args":{"space":"default","tuple":["task","worker","go"]}}
      - read {space, pattern, timeout}: blocking non-destructive read (ms). Returns the matched tuple as an array.
      - take {space, pattern, timeout}: blocking destructive read.
      - read_nowait {space, pattern}: non-blocking peek.
      - take_nowait {space, pattern}: non-blocking consume.
      - list_spaces {}: list all running space names.
      - create_space {name}: start a named space.
      - destroy_space {name}: stop a named space.
    """
  end

  @impl true
  def perform("write", %{"space" => space, "tuple" => tuple}) when is_list(tuple) do
    case TS.out(space_name(space), encode_tuple(tuple)) do
      :ok -> {:ok, %{output: "ok", metadata: %{action: "write"}}}
      {:error, reason} -> ts_error(reason)
    end
  end

  def perform("read", %{"space" => space, "pattern" => pattern, "timeout" => timeout})
      when is_list(pattern) and is_integer(timeout) do
    case TS.rd(space_name(space), encode_tuple(pattern), timeout) do
      {:ok, tuple} -> {:ok, %{output: decode_tuple(tuple), metadata: %{action: "read"}}}
      {:error, reason} -> ts_error(reason)
    end
  end

  def perform("take", %{"space" => space, "pattern" => pattern, "timeout" => timeout})
      when is_list(pattern) and is_integer(timeout) do
    case TS.in_(space_name(space), encode_tuple(pattern), timeout) do
      {:ok, tuple} -> {:ok, %{output: decode_tuple(tuple), metadata: %{action: "take"}}}
      {:error, reason} -> ts_error(reason)
    end
  end

  def perform("read_nowait", %{"space" => space, "pattern" => pattern}) when is_list(pattern) do
    case TS.rd_nowait(space_name(space), encode_tuple(pattern)) do
      {:ok, tuple} -> {:ok, %{output: decode_tuple(tuple), metadata: %{action: "read_nowait"}}}
      {:error, reason} -> ts_error(reason)
    end
  end

  def perform("take_nowait", %{"space" => space, "pattern" => pattern}) when is_list(pattern) do
    case TS.in_nowait(space_name(space), encode_tuple(pattern)) do
      {:ok, tuple} -> {:ok, %{output: decode_tuple(tuple), metadata: %{action: "take_nowait"}}}
      {:error, reason} -> ts_error(reason)
    end
  end

  def perform("list_spaces", _args) do
    spaces = TS.list_spaces() |> Enum.map(&Atom.to_string/1)
    {:ok, %{output: spaces, metadata: %{action: "list_spaces"}}}
  end

  def perform("create_space", %{"name" => name}) when is_binary(name) do
    case TS.start_space(space_name(name)) do
      {:ok, _pid} -> {:ok, %{output: "ok", metadata: %{action: "create_space"}}}
      {:error, {:already_started, _}} ->
        {:error, ErrorStruct.new("already_started", "name", "Space #{name} is already running")}
      {:error, reason} -> ts_error(reason)
    end
  end

  def perform("destroy_space", %{"name" => name}) when is_binary(name) do
    case TS.stop_space(space_name(name)) do
      :ok -> {:ok, %{output: "ok", metadata: %{action: "destroy_space"}}}
      {:error, :not_found} ->
        {:error, ErrorStruct.new("not_found", "name", "Space #{name} not found")}
      {:error, reason} -> ts_error(reason)
    end
  end

  def perform(_, _),
    do: {:error, ErrorStruct.new("unknown_command", nil, "Unrecognized TupleSpace action")}

  ## Encoding helpers

  defp space_name(name) when is_atom(name), do: name
  defp space_name(name) when is_binary(name), do: String.to_atom(name)

  # JSON list -> Erlang tuple, with "_" -> :_ for wildcard.
  defp encode_tuple(list) when is_list(list) do
    list
    |> Enum.map(&encode_elem/1)
    |> List.to_tuple()
  end

  defp encode_elem("_"), do: :_
  defp encode_elem(other), do: other

  # Erlang tuple -> JSON-friendly list.
  defp decode_tuple(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&decode_elem/1)
  end

  defp decode_elem(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp decode_elem(other), do: other

  ## Error mapping

  defp ts_error(:timeout), do: {:error, ErrorStruct.new("timeout", nil, "operation timed out")}
  defp ts_error(:no_match), do: {:error, ErrorStruct.new("no_match", nil, "no matching tuple")}
  defp ts_error(:space_not_found), do: {:error, ErrorStruct.new("space_not_found", "space", "tuple space not found")}
  defp ts_error(other), do: {:error, ErrorStruct.new("tuple_space_error", nil, inspect(other))}
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/tools/tuple_space_tool_test.exs`

Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add lib/tools/tuple_space.ex test/tools/tuple_space_tool_test.exs
git commit -m "Add TupleSpace tool — JSON adapter over LLMAgent.TupleSpace"
```

---

## Task 7: Register `:tuple_space` in the tools registry

**Files:**
- Modify: `lib/tools.ex`
- Test: `lib/tools.ex` doctest update

- [ ] **Step 1: Update doctest expectation (RED)**

In `lib/tools.ex`, the module doctest at line ~16 reads:

```elixir
      iex> LLMAgent.Tools.all() |> Keyword.keys() |> Enum.sort()
      [:bash, :crypto, :dbus, :file, :inotify, :net, :proc, :systemd, :udev, :web]
```

Change the expected list to include `:tuple_space`:

```elixir
      iex> LLMAgent.Tools.all() |> Keyword.keys() |> Enum.sort()
      [:bash, :crypto, :dbus, :file, :inotify, :net, :proc, :systemd, :tuple_space, :udev, :web]
```

- [ ] **Step 2: Run doctests to verify they fail**

Run: `mix test test/doctest_test.exs`

Expected: The Tools doctest fails — actual list does not include `:tuple_space`.

- [ ] **Step 3: Register the tool**

In `lib/tools.ex`, modify the alias block and `@builtins`:

```elixir
  alias LLMAgent.Tools.{
    Bash,
    Web,
    DBus,
    Systemd,
    Inotify,
    Udev,
    File,
    Net,
    Proc,
    Crypto,
    TupleSpace
  }

  @builtins [
    bash: Bash,
    web: Web,
    dbus: DBus,
    systemd: Systemd,
    inotify: Inotify,
    udev: Udev,
    file: File,
    net: Net,
    proc: Proc,
    crypto: Crypto,
    tuple_space: TupleSpace
  ]
```

Add a convenience accessor at the bottom of the module:

```elixir
  @doc "Returns the TupleSpace tool module."
  @spec tuple_space() :: module()
  def tuple_space, do: get!(:tuple_space)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test`

Expected: All pass. (The other doctest at line 18 — `length(tools) >= 10` — still passes; it is a lower bound.)

- [ ] **Step 5: Commit**

```bash
git add lib/tools.ex
git commit -m "Register :tuple_space in tools registry"
```

---

## Task 8: Implement Agent tool — async spawn, kill, list, status

**Files:**
- Create: `lib/tools/agent.ex`
- Test: `test/tools/agent_tool_test.exs`

We start with async because it is the simpler shape (no blocking on result). Sync mode comes in Task 9.

- [ ] **Step 1: Write the failing tests**

Create `test/tools/agent_tool_test.exs`:

```elixir
defmodule LLMAgent.Tools.AgentTest do
  use ExUnit.Case, async: false

  alias LLMAgent.Tools.Agent, as: AgentTool
  alias LLMAgent.TupleSpace
  alias Comn.Errors.ErrorStruct
  alias Comn.Contexts

  setup do
    TupleSpace.stop_space(:default)
    {:ok, _} = TupleSpace.start_space(:default)

    # Simulate being inside a root agent's process: put name + nil parent into Contexts.
    Contexts.new(%{request_id: "test", trace_id: "test", actor: "test"})
    Contexts.put(:agent_name, :test_root_caller)
    Contexts.put(:agent_parent, nil)

    on_exit(fn ->
      # Clean up any agents started during the test
      for pid <- LLMAgent.AgentSupervisor.list_agents() do
        DynamicSupervisor.terminate_child(LLMAgent.AgentSupervisor, pid)
      end
    end)

    :ok
  end

  describe "describe/0" do
    test "lists all actions" do
      desc = AgentTool.describe()
      for a <- ~w(spawn kill list status), do: assert desc =~ a
    end
  end

  describe "spawn (async)" do
    test "starts a child and returns immediately" do
      args = %{
        "name" => "child_a",
        "prompt" => "noop",
        "tools" => ["bash"],
        "mode" => "async"
      }

      assert {:ok, %{output: output}} = AgentTool.perform("spawn", args)
      assert output =~ "child_a"
      assert output =~ "started"

      # Process is alive
      assert is_pid(GenServer.whereis({:global, :child_a}))
    end

    test "child has parent and allowed_tools set" do
      AgentTool.perform("spawn", %{
        "name" => "child_b",
        "prompt" => "noop",
        "tools" => ["file", "bash"],
        "mode" => "async"
      })

      state = :sys.get_state({:global, :child_b})
      assert state.parent == :test_root_caller
      assert state.allowed_tools == [:file, :bash]
    end
  end

  describe "list, status, kill" do
    test "list returns running children" do
      AgentTool.perform("spawn", %{
        "name" => "child_l",
        "prompt" => "noop",
        "tools" => ["bash"],
        "mode" => "async"
      })

      {:ok, %{output: agents}} = AgentTool.perform("list", %{})
      names = Enum.map(agents, & &1["name"])
      assert "child_l" in names
    end

    test "status of a running child" do
      AgentTool.perform("spawn", %{
        "name" => "child_s",
        "prompt" => "noop",
        "tools" => ["bash"],
        "mode" => "async"
      })

      assert {:ok, %{output: %{"running" => true, "name" => "child_s"}}} =
               AgentTool.perform("status", %{"name" => "child_s"})
    end

    test "status of a missing child" do
      assert {:ok, %{output: %{"running" => false, "name" => "missing_x"}}} =
               AgentTool.perform("status", %{"name" => "missing_x"})
    end

    test "kill stops a child" do
      AgentTool.perform("spawn", %{
        "name" => "child_k",
        "prompt" => "noop",
        "tools" => ["bash"],
        "mode" => "async"
      })

      assert {:ok, %{output: "ok"}} = AgentTool.perform("kill", %{"name" => "child_k"})
      assert GenServer.whereis({:global, :child_k}) == nil
    end

    test "kill missing child returns error" do
      assert {:error, %ErrorStruct{reason: "not_found"}} =
               AgentTool.perform("kill", %{"name" => "missing_k"})
    end
  end

  describe "unknown action" do
    test "returns unknown_command" do
      assert {:error, %ErrorStruct{reason: "unknown_command"}} = AgentTool.perform("nope", %{})
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/tools/agent_tool_test.exs`

Expected: All fail — module does not exist.

- [ ] **Step 3: Implement the tool (async + lifecycle only)**

Create `lib/tools/agent.ex`:

```elixir
defmodule LLMAgent.Tools.Agent do
  @moduledoc """
  Lifecycle-only tool for spawning, killing, listing, and inspecting child agents.

  Communication between parent and child happens through the tuple space — see
  `LLMAgent.Tools.TupleSpace`. This tool intentionally does not carry payloads.

  Caller identity (`agent_name`, `agent_parent`) is read from `Comn.Contexts`,
  populated by `LLMAgent` on each prompt.
  """

  @behaviour LLMAgent.Tool
  alias LLMAgent.AgentSupervisor
  alias LLMAgent.TupleSpace, as: TS
  alias Comn.Errors.ErrorStruct
  alias Comn.Contexts

  @default_sync_timeout 120_000

  @impl true
  def describe do
    """
    Spawn and manage child agents. One level deep — children cannot spawn further.

    Actions:
      - spawn {name, prompt, tools, mode, model?, timeout?}: start a child agent.
        - mode: "sync" blocks for the child's final response.
        - mode: "async" returns immediately; child writes {:agent_result, name, content}
          to the :default tuple space on completion.
        - tools: array of tool name strings (whitelist).
      - kill {name}: stop a running child.
      - list {}: list running children with state.
      - status {name}: { running: bool, name: string }.
    """
  end

  @impl true
  def perform("spawn", args), do: do_spawn(args)

  def perform("kill", %{"name" => name}) when is_binary(name) do
    case AgentSupervisor.stop_agent(String.to_atom(name)) do
      :ok -> {:ok, %{output: "ok", metadata: %{action: "kill"}}}
      {:error, :not_found} ->
        {:error, ErrorStruct.new("not_found", "name", "agent #{name} not found")}
    end
  end

  def perform("list", _args) do
    list =
      AgentSupervisor.list_agents_with_state()
      |> Enum.map(fn s ->
        %{
          "name" => Atom.to_string(s.name),
          "role" => Atom.to_string(s.role),
          "model" => s.model,
          "history_length" => s.history_length
        }
      end)

    {:ok, %{output: list, metadata: %{action: "list"}}}
  end

  def perform("status", %{"name" => name}) when is_binary(name) do
    running = GenServer.whereis({:global, String.to_atom(name)}) != nil
    {:ok, %{output: %{"running" => running, "name" => name}, metadata: %{action: "status"}}}
  end

  def perform(_, _),
    do: {:error, ErrorStruct.new("unknown_command", nil, "Unrecognized Agent action")}

  ## Spawn

  defp do_spawn(%{"name" => name, "prompt" => prompt, "tools" => tools, "mode" => mode} = args)
       when is_binary(name) and is_binary(prompt) and is_list(tools) and is_binary(mode) do
    caller_parent = Contexts.get(:agent_parent)
    caller_name = Contexts.get(:agent_name)

    cond do
      caller_parent != nil ->
        {:error,
         ErrorStruct.new("spawn_depth_exceeded", nil,
           "child agents cannot spawn further agents")}

      true ->
        spawn_with_mode(mode, name, prompt, tools, caller_name, args)
    end
  end

  defp do_spawn(_),
    do: {:error, ErrorStruct.new("invalid_args", nil, "spawn requires name, prompt, tools, mode")}

  defp spawn_with_mode("async", name, prompt, tools, parent, args) do
    case start_child(name, prompt, tools, parent, args) do
      {:ok, _pid} ->
        # fire the prompt without blocking
        LLMAgent.prompt({:global, String.to_atom(name)}, prompt)
        {:ok, %{output: "agent #{name} started", metadata: %{action: "spawn", mode: "async"}}}

      {:error, reason} ->
        {:error,
         ErrorStruct.new("spawn_failed", "name", "could not start #{name}: #{inspect(reason)}")}
    end
  end

  defp spawn_with_mode("sync", _name, _prompt, _tools, _parent, _args) do
    # Implemented in Task 9
    {:error, ErrorStruct.new("not_implemented", "mode", "sync mode not yet implemented")}
  end

  defp spawn_with_mode(other, _name, _prompt, _tools, _parent, _args) do
    {:error, ErrorStruct.new("invalid_mode", "mode", "unknown spawn mode: #{other}")}
  end

  defp start_child(name, _prompt, tools, parent, args) do
    opts = [
      name: String.to_atom(name),
      parent: parent,
      allowed_tools: Enum.map(tools, &String.to_atom/1)
    ]

    opts =
      case Map.get(args, "model") do
        nil -> opts
        model when is_binary(model) -> Keyword.put(opts, :model, model)
      end

    AgentSupervisor.start_agent(opts)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/tools/agent_tool_test.exs`

Expected: All pass except any that touch sync mode (none in this task).

- [ ] **Step 5: Run full suite**

Run: `mix test`

Expected: All pass.

- [ ] **Step 6: Commit**

```bash
git add lib/tools/agent.ex test/tools/agent_tool_test.exs
git commit -m "Add Agent tool — async spawn, kill, list, status"
```

---

## Task 9: Implement sync spawn mode

**Files:**
- Modify: `lib/tools/agent.ex` (`spawn_with_mode("sync", ...)`)
- Test: `test/tools/agent_tool_test.exs` (extend)

Sync flow:

1. Start the child under `AgentSupervisor` with the same opts.
2. Fire `LLMAgent.prompt(child, prompt)`.
3. Block on `LLMAgent.TupleSpace.in_(:default, {:agent_result, child_name, :_}, timeout)`.
4. On `{:ok, {:agent_result, _, content}}`, return content.
5. On `{:error, :timeout}`, kill the child and return a timeout error.

Child completion path (Task 3) already writes the tuple, so we just consume it.

- [ ] **Step 1: Write the failing tests**

Append to `test/tools/agent_tool_test.exs`:

```elixir
  describe "spawn (sync)" do
    test "blocks until child writes result, returns content" do
      # Pre-stage the result so the spawn returns quickly.
      # We need the child name to match what spawn produces.
      Task.start(fn ->
        Process.sleep(40)
        TupleSpace.out({:agent_result, :child_sync_ok, "the answer"})
        Process.sleep(20)
        # Stop the child to release the supervisor child slot
        LLMAgent.AgentSupervisor.stop_agent(:child_sync_ok)
      end)

      args = %{
        "name" => "child_sync_ok",
        "prompt" => "noop",
        "tools" => ["bash"],
        "mode" => "sync",
        "timeout" => 1_000
      }

      assert {:ok, %{output: "the answer"}} = AgentTool.perform("spawn", args)
    end

    test "times out and kills the child if no result arrives" do
      args = %{
        "name" => "child_sync_to",
        "prompt" => "noop",
        "tools" => ["bash"],
        "mode" => "sync",
        "timeout" => 100
      }

      assert {:error, %ErrorStruct{reason: "timeout"}} = AgentTool.perform("spawn", args)
      # Child has been cleaned up
      assert GenServer.whereis({:global, :child_sync_to}) == nil
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/tools/agent_tool_test.exs`

Expected: Both new tests fail (`not_implemented`).

- [ ] **Step 3: Implement sync mode**

Replace the placeholder `spawn_with_mode("sync", ...)` clause in `lib/tools/agent.ex`:

```elixir
  defp spawn_with_mode("sync", name, prompt, tools, parent, args) do
    timeout = Map.get(args, "timeout", @default_sync_timeout)
    name_atom = String.to_atom(name)

    case start_child(name, prompt, tools, parent, args) do
      {:ok, _pid} ->
        LLMAgent.prompt({:global, name_atom}, prompt)

        case TS.in_(:default, {:agent_result, name_atom, :_}, timeout) do
          {:ok, {:agent_result, ^name_atom, content}} ->
            # Child self-terminates on completion (Task 3); ensure cleanup either way.
            AgentSupervisor.stop_agent(name_atom)

            {:ok,
             %{output: content, metadata: %{action: "spawn", mode: "sync", name: name}}}

          {:error, :timeout} ->
            AgentSupervisor.stop_agent(name_atom)

            {:error,
             ErrorStruct.new("timeout", "timeout",
               "agent :#{name} timed out after #{timeout}ms")}

          {:error, reason} ->
            AgentSupervisor.stop_agent(name_atom)

            {:error,
             ErrorStruct.new("spawn_failed", nil,
               "sync wait failed: #{inspect(reason)}")}
        end

      {:error, reason} ->
        {:error,
         ErrorStruct.new("spawn_failed", "name", "could not start #{name}: #{inspect(reason)}")}
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/tools/agent_tool_test.exs`

Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add lib/tools/agent.ex test/tools/agent_tool_test.exs
git commit -m "Implement sync spawn mode in Agent tool"
```

---

## Task 10: Register `:agent` in the tools registry

**Files:**
- Modify: `lib/tools.ex`

- [ ] **Step 1: Update the doctest expectation (RED)**

Change the sorted-keys doctest to include `:agent`:

```elixir
      iex> LLMAgent.Tools.all() |> Keyword.keys() |> Enum.sort()
      [:agent, :bash, :crypto, :dbus, :file, :inotify, :net, :proc, :systemd, :tuple_space, :udev, :web]
```

- [ ] **Step 2: Run doctests to verify they fail**

Run: `mix test test/doctest_test.exs`

Expected: Tools doctest fails.

- [ ] **Step 3: Register the Agent tool**

In `lib/tools.ex`:

```elixir
  alias LLMAgent.Tools.{
    Bash,
    Web,
    DBus,
    Systemd,
    Inotify,
    Udev,
    File,
    Net,
    Proc,
    Crypto,
    TupleSpace,
    Agent
  }

  @builtins [
    bash: Bash,
    web: Web,
    dbus: DBus,
    systemd: Systemd,
    inotify: Inotify,
    udev: Udev,
    file: File,
    net: Net,
    proc: Proc,
    crypto: Crypto,
    tuple_space: TupleSpace,
    agent: Agent
  ]
```

Add convenience accessor:

```elixir
  @doc "Returns the Agent tool module."
  @spec agent() :: module()
  def agent, do: get!(:agent)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test`

Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add lib/tools.ex
git commit -m "Register :agent in tools registry"
```

---

## Task 11: Integration tests — end-to-end orchestration scenarios

**Files:**
- Create: `test/agent_orchestration_test.exs`

Cover the spec's testing checklist:
1. Root spawns sync child, gets result back
2. Root spawns async child, collects from tuple space
3. Child attempts spawn → denied
4. Parent dies → orphan continues, writes result
5. Child crashes → error tuple lands in tuple space
6. Child attempts disallowed tool → rejected

The unit tests already cover #3, #4, #5, and #6 individually. This file proves they work together with real agent processes driving the Agent tool through the tool-call loop.

- [ ] **Step 1: Write the integration tests**

Create `test/agent_orchestration_test.exs`:

```elixir
defmodule LLMAgent.AgentOrchestrationTest do
  @moduledoc """
  End-to-end orchestration: a root agent spawns children via the Agent tool
  and coordinates with them through the tuple space.
  """
  use ExUnit.Case, async: false

  alias LLMAgent.TupleSpace
  alias LLMAgent.EventLog

  setup do
    EventLog.clear()
    TupleSpace.stop_space(:default)
    {:ok, _} = TupleSpace.start_space(:default)
    LLMAgent.DurableLog.clear()
    :ok
  end

  defp start_agent(name, opts \\ []) do
    {:ok, pid} = LLMAgent.start_link([{:name, name} | opts])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop({:global, name}) end)
    pid
  end

  defp simulate_llm(pid, content) do
    ref = make_ref()
    send(pid, {ref, {:ok, content}})
    Process.sleep(60)
  end

  defp tool_json(tool, action, args) do
    Jason.encode!(%{"tool" => tool, "action" => action, "args" => args})
  end

  describe "async fan-out / fan-in" do
    test "root spawns async child, collects result from tuple space" do
      root = start_agent(:orch_root_async)

      simulate_llm(root, tool_json("agent", "spawn", %{
        "name" => "orch_async_child",
        "prompt" => "do work",
        "tools" => ["bash"],
        "mode" => "async"
      }))

      # Child is running with parent set
      assert is_pid(GenServer.whereis({:global, :orch_async_child}))
      child_state = :sys.get_state({:global, :orch_async_child})
      assert child_state.parent == :orch_root_async
      assert child_state.allowed_tools == [:bash]

      # Simulate the child finishing
      child_pid = GenServer.whereis({:global, :orch_async_child})
      simulate_llm(child_pid, "child done")

      # Result tuple landed
      assert {:ok, {:agent_result, :orch_async_child, "child done"}} =
               TupleSpace.in_nowait({:agent_result, :orch_async_child, :_})
    end
  end

  describe "spawn depth enforcement" do
    test "child attempting to spawn a grandchild gets denied" do
      _root = start_agent(:orch_dn_root)

      # Spawn a child by hand with parent set, simulating that the root spawned it.
      {:ok, child_pid} =
        LLMAgent.AgentSupervisor.start_agent(
          name: :orch_dn_child,
          parent: :orch_dn_root,
          allowed_tools: [:agent]
        )

      on_exit(fn ->
        if Process.alive?(child_pid),
          do: LLMAgent.AgentSupervisor.stop_agent(:orch_dn_child)
      end)

      # Drive the child's tool loop with an Agent.spawn call
      LLMAgent.prompt({:global, :orch_dn_child}, "go")
      simulate_llm(child_pid, tool_json("agent", "spawn", %{
        "name" => "grandchild",
        "prompt" => "x",
        "tools" => ["bash"],
        "mode" => "async"
      }))

      state = :sys.get_state({:global, :orch_dn_child})
      function_msg = Enum.find(state.history, &(&1.role == "function"))
      assert function_msg.content =~ "spawn_depth_exceeded"
      assert GenServer.whereis({:global, :grandchild}) == nil
    end
  end

  describe "whitelist enforcement under orchestration" do
    test "child rejecting disallowed tool produces error result, no dispatch" do
      _root = start_agent(:orch_wl_root)

      {:ok, child_pid} =
        LLMAgent.AgentSupervisor.start_agent(
          name: :orch_wl_child,
          parent: :orch_wl_root,
          allowed_tools: [:file]
        )

      on_exit(fn ->
        if Process.alive?(child_pid),
          do: LLMAgent.AgentSupervisor.stop_agent(:orch_wl_child)
      end)

      LLMAgent.prompt({:global, :orch_wl_child}, "go")
      simulate_llm(child_pid, tool_json("bash", "exec", %{"command" => "echo blocked"}))

      state = :sys.get_state({:global, :orch_wl_child})
      function_msg = Enum.find(state.history, &(&1.role == "function"))
      assert function_msg.content =~ "tool :bash not permitted"
    end
  end

  describe "orphan resilience" do
    test "child whose parent dies still writes result to tuple space" do
      parent_pid = start_agent(:orch_orph_parent)

      {:ok, child_pid} =
        LLMAgent.AgentSupervisor.start_agent(
          name: :orch_orph_child,
          parent: :orch_orph_parent,
          allowed_tools: [:bash]
        )

      on_exit(fn ->
        if Process.alive?(child_pid),
          do: LLMAgent.AgentSupervisor.stop_agent(:orch_orph_child)
      end)

      # Kill the parent before the child finishes
      GenServer.stop(parent_pid)
      Process.sleep(40)

      # Child finishes anyway
      simulate_llm(child_pid, "orphaned but done")

      assert {:ok, {:agent_result, :orch_orph_child, "orphaned but done"}} =
               TupleSpace.in_nowait({:agent_result, :orch_orph_child, :_})
    end
  end

  describe "child crash propagation" do
    test "abnormal exit writes {:agent_error, name, reason}" do
      _root = start_agent(:orch_crash_root)

      {:ok, child_pid} =
        LLMAgent.AgentSupervisor.start_agent(
          name: :orch_crash_child,
          parent: :orch_crash_root,
          allowed_tools: [:bash]
        )

      Process.flag(:trap_exit, true)
      Process.exit(child_pid, :forced_crash)
      Process.sleep(60)

      assert {:ok, {:agent_error, :orch_crash_child, _reason}} =
               TupleSpace.in_nowait({:agent_error, :orch_crash_child, :_})
    end
  end
end
```

- [ ] **Step 2: Run the integration tests**

Run: `mix test test/agent_orchestration_test.exs`

Expected: All pass. If any fail, the failure is most likely in the timing of `Process.sleep` calls or in the interaction between `terminate/2` and the supervisor — investigate the offending test, do not relax assertions.

- [ ] **Step 3: Run the full suite**

Run: `mix test`

Expected: All pass.

- [ ] **Step 4: Commit**

```bash
git add test/agent_orchestration_test.exs
git commit -m "Add integration tests for agent orchestration"
```

---

## Task 12: Documentation update — TRYIT walkthrough

**Files:**
- Modify: `docs/TRYIT.md` (add an orchestration section at the end)

This is a docs-only task. The new tools should be reachable from the iex walkthrough.

- [ ] **Step 1: Read the current TRYIT to find the right spot**

Run: `wc -l docs/TRYIT.md && tail -30 docs/TRYIT.md`

- [ ] **Step 2: Append an orchestration section**

Append the following to `docs/TRYIT.md`:

```markdown

## Agent orchestration

The `agent` tool spawns child agents under the existing `AgentSupervisor`, and
the `tuple_space` tool gives them a coordination surface. Tuples from the LLM
are JSON arrays; `"_"` is the wildcard. Children's tool access is whitelisted
per spawn.

Async spawn:

```elixir
LLMAgent.Tools.Agent.perform("spawn", %{
  "name" => "worker",
  "prompt" => "summarize the contents of /etc/hostname",
  "tools" => ["file"],
  "mode" => "async"
})
```

Result lands in the default tuple space:

```elixir
LLMAgent.TupleSpace.in_(:default, {:agent_result, :worker, :_}, 30_000)
```

Sync spawn (blocks until the child finishes, then stops it):

```elixir
LLMAgent.Tools.Agent.perform("spawn", %{
  "name" => "summarizer",
  "prompt" => "say hello",
  "tools" => ["bash"],
  "mode" => "sync",
  "timeout" => 30_000
})
```

Through the tuple_space tool directly:

```elixir
LLMAgent.Tools.TupleSpace.perform("write",
  %{"space" => "default", "tuple" => ["task", "worker", "do thing"]})

LLMAgent.Tools.TupleSpace.perform("take",
  %{"space" => "default", "pattern" => ["task", "_", "_"], "timeout" => 5_000})
```
```

- [ ] **Step 3: Commit**

```bash
git add docs/TRYIT.md
git commit -m "Document agent orchestration in TRYIT walkthrough"
```

---

## Self-Review

**Spec coverage** — every section of the spec is mapped to a task:

| Spec section | Task(s) |
|---|---|
| TupleSpace tool actions (write/read/take/_nowait/list/create/destroy) | 6 |
| TupleSpace data encoding (JSON ↔ tuples, `"_"` ↔ `:_`) | 6 (encode_tuple/decode_tuple/encode_elem/decode_elem) |
| Agent tool actions (spawn/kill/list/status) | 8 |
| Spawn modes — sync | 9 |
| Spawn modes — async | 8 |
| Spawn depth enforcement | 8 (do_spawn checks Contexts.get(:agent_parent)); integration test in 11 |
| Agent state changes — `parent` and `allowed_tools` | 1 |
| Tool dispatch whitelist check | 2 |
| Conversation completion for child agents | 3 |
| Child crash → `{:agent_error, ...}` | 4 |
| Sync timeout → kill + error | 9 |
| Orphan behavior | 5 |
| Files changed: `lib/tools/tuple_space.ex` | 6 |
| Files changed: `lib/tools/agent.ex` | 8, 9 |
| Files changed: `lib/LLMAgent.ex` | 1, 2, 3, 4, 5 |
| Files changed: `lib/tools.ex` | 7, 10 |
| Tests: TupleSpace tool unit | 6 |
| Tests: Agent tool unit | 8, 9 |
| Tests: integration scenarios | 11 |

**Type consistency** — names used in later tasks all match earlier definitions:
- `state.parent` (atom | nil) — Task 1, used by Tasks 2, 3, 4, 5
- `state.allowed_tools` (`[atom]` | `:all`) — Task 1, used by Task 2
- `state.parent_ref` (reference | nil) — Task 5, internal only
- `Contexts.get(:agent_name)` and `Contexts.get(:agent_parent)` — Task 1, used by Task 8
- `{:agent_result, name, content}` — Task 3, consumed by Task 9 sync wait and integration tests in Task 11
- `{:agent_error, name, reason}` — Task 4, consumed by integration test in Task 11
- `LLMAgent.Tools.TupleSpace` — Task 6, registered in Task 7
- `LLMAgent.Tools.Agent` — Tasks 8 and 9, registered in Task 10
- `:tuple_space`, `:agent` — Tasks 7 and 10
- Sorted doctest list updated incrementally: Task 7 adds `:tuple_space`, Task 10 adds `:agent`
- `@default_sync_timeout` — Task 8 defines, Task 9 uses

**Placeholder scan** — no TBDs, TODOs, "fill in", or hand-waved test scaffolding. Every test step shows the test code; every implementation step shows the implementation code.

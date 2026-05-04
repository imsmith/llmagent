defmodule LLMAgent.Tool.Adapter.Module do
  @moduledoc """
  Adapter for `:module` bindings. The binding payload is a module atom that
  directly implements the relevant kind behaviour(s). Each adapter callback
  is a straight pass-through to the corresponding function on that module.

  This is the simplest possible binding: the tool implementation lives in an
  Elixir module on the same node, loaded into the VM. No serialisation, no
  network, no process boundary. Use it for built-in tools, test fixtures, and
  any implementation that does not need process isolation.

  The payload in `ToolAd.binding` is `{:module, MyModule}`. `MyModule` must
  implement whichever kind behaviours are declared in `ToolAd.kinds`.

  See `docs/superpowers/specs/2026-05-03-tool-discovery-design.md` §4.2.

  ## Example

  Given a module implementing `LLMAgent.Tool.Kinds.Compute`:

  ```elixir
  # in iex or a test:
  # Doubler.compute("double", %{"n" => 5}) #=> {:ok, 10}
  LLMAgent.Tool.Adapter.Module.compute(Doubler, "double", %{"n" => 5}, [])
  #=> {:ok, 10}
  ```

  The call is equivalent to `Doubler.compute("double", %{"n" => 5})` — the
  adapter simply drops the `opts` keyword list which the kind callback does
  not accept.
  """

  @behaviour LLMAgent.Tool.Adapter

  @impl true
  @doc "Pass through to the module's `query/2` callback."
  def query(mod, action, args, _opts), do: mod.query(action, args)

  @impl true
  @doc "Pass through to the module's `act/3` callback."
  def act(mod, action, args, idempotency_key, _opts),
    do: mod.act(action, args, idempotency_key)

  @impl true
  @doc "Pass through to the module's `subscribe/3` callback."
  def subscribe(mod, action, args, subscriber, _opts),
    do: mod.subscribe(action, args, subscriber)

  @impl true
  @doc "Pass through to the module's `unsubscribe/1` callback."
  def unsubscribe(mod, sub_ref, _opts), do: mod.unsubscribe(sub_ref)

  @impl true
  @doc "Pass through to the module's `compute/2` callback."
  def compute(mod, action, args, _opts), do: mod.compute(action, args)

  @impl true
  @doc "Pass through to the module's `participate/3` callback."
  def participate(mod, role, args, opts), do: mod.participate(role, args, opts)

  @impl true
  @doc "Pass through to the module's `leave/1` callback."
  def leave(mod, participation_ref, _opts), do: mod.leave(participation_ref)

  @impl true
  @doc "Pass through to the module's `spawn_child/2` callback."
  def spawn_child(mod, spec, opts), do: mod.spawn_child(spec, opts)

  @impl true
  @doc "Pass through to the module's `child_status/1` callback."
  def child_status(mod, child_ref, _opts), do: mod.child_status(child_ref)

  @impl true
  @doc "Pass through to the module's `terminate_child/2` callback."
  def terminate_child(mod, child_ref, reason, _opts),
    do: mod.terminate_child(child_ref, reason)
end

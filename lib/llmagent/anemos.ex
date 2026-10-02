defmodule LLMAgent.Anemos do
  @moduledoc """
  Every discovered tool, as an Anemos module.

  Start one next to the runtime it serves:

      {Anemos.Runtime, name: :anemos},
      {LLMAgent.Anemos, runtime: :anemos, policy: %LLMAgent.Tool.Policy{allow: ["resource.*"]}}

  Then a policy can say `[RESOURCE_NET::ping :host "skynet001.local"]`: the
  coordinate `resource.net`, uppercased with dots as underscores, is the
  module; the action is the verb; the arguments are key-value pairs. The
  call goes through `LLMAgent.Tool.Dispatcher` under the policy given here,
  which is where it is allowed or refused.

  Every ad in `LLMAgent.Tools.Discovery` is registered with the runtime under
  its name when this starts, and every ad that arrives later is registered
  as it arrives. See `docs/superpowers/specs/2026-10-02-anemos-verbs-design.md`.

  ## The attachment is the authority

  A verb asks this process, at every call, for the policy and for the
  coordinate behind its name. Stop the attachment and every tool verb
  answers `{:error, :detached}`; restart it with another policy and the
  rights change. The runtime's own module registry is write-once, so the
  *names* stay bound; what they reach is decided here.

  ## Tools are not trusted with the dispatcher

  A verb runs inside the Anemos dispatcher, the one process every rule in
  the runtime goes through. A tool is run in a process of its own, with a
  deadline (`:verb_timeout_ms`, default 4000 — under the 5 seconds a
  `dispatch/3` caller waits), and whatever it does — raise, exit, call back
  into the runtime and wait on itself, take a minute — comes back as an
  `{:error, _}` to the rule and nothing else.

  A policy with `require_approval` rules is refused at start: an approval
  waits for a human, and a verb cannot.
  """

  use GenServer

  require Logger

  alias LLMAgent.{ToolAd, ToolQuery, Tool.Dispatcher, Tool.Policy, Tools.Discovery}

  @behaviour Anemos.Runtime.Module

  # Side-effect-free kinds first. A kind that does not know the action
  # yields to the next; the first answer that is not that is the answer.
  @kind_order [:query, :compute, :generate, :action]

  @default_timeout_ms 4_000

  @typedoc "One verb a policy can call."
  @type verb :: %{
          module: String.t(),
          verb: String.t(),
          coordinate: String.t(),
          kinds: [atom()],
          idempotency: atom() | nil,
          blast_radius: atom() | nil
        }

  @doc """
  Start the attachment. Options: `:runtime` (the `Anemos.Runtime` name,
  required), `:policy` (a `%LLMAgent.Tool.Policy{}`; default denies all),
  `:verb_timeout_ms` (default #{@default_timeout_ms}).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    runtime = Keyword.fetch!(opts, :runtime)
    GenServer.start_link(__MODULE__, opts, name: name_for(runtime))
  end

  @doc "The registered name of the attachment serving `runtime`."
  @spec name_for(atom()) :: atom()
  def name_for(runtime), do: :"#{runtime}.llmagent"

  @doc "The Anemos module name for a coordinate: `resource.net` is `RESOURCE_NET`."
  @spec module_name(String.t()) :: String.t()
  def module_name(coordinate), do: coordinate |> String.replace(".", "_") |> String.upcase()

  @doc """
  Every verb a policy could call, with what the ad says about it. An ad
  that declares no actions is listed once, as verb `"*"`: anything may be
  asked of it, and the ad says nothing about any of it.
  """
  @spec verbs() :: [verb()]
  def verbs do
    {:ok, ads} = Discovery.find_all(ToolQuery.new(%{coordinate: "*"}))

    for ad <- Enum.sort_by(ads, & &1.coordinate),
        action <- actions(ad) do
      %{
        module: module_name(ad.coordinate),
        verb: action,
        coordinate: ad.coordinate,
        kinds: ad.kinds,
        idempotency: get_in(ad.constraint, [:idempotency, action]),
        blast_radius: get_in(ad.constraint, [:blast_radius, action])
      }
    end
  end

  defp actions(ad) do
    case ad.operational |> Map.get(:actions, %{}) |> Map.keys() |> Enum.sort() do
      [] -> ["*"]
      actions -> actions
    end
  end

  # --- server ---

  @impl true
  def init(opts) do
    runtime = Keyword.fetch!(opts, :runtime)
    policy = Keyword.get(opts, :policy, %Policy{})

    if policy.require_approval != [] do
      {:stop, {:require_approval_not_supported, policy.require_approval}}
    else
      everything = ToolQuery.new(%{coordinate: "*"})
      :ok = Discovery.subscribe(everything, self())
      {:ok, ads} = Discovery.find_all(everything)

      state = %{
        runtime: runtime,
        policy: policy,
        timeout_ms: Keyword.get(opts, :verb_timeout_ms, @default_timeout_ms),
        # module name => coordinate
        names: %{}
      }

      {:ok, Enum.reduce(ads, state, &bind(&2, &1.coordinate))}
    end
  end

  @impl true
  def handle_info({event, _id, coordinate}, state) when event in [:tool_added, :tool_updated] do
    {:noreply, bind(state, coordinate)}
  end

  # Only the name this coordinate held, and only if it still holds it: a
  # later ad that took the name over is not unbound by the earlier one
  # leaving.
  def handle_info({:tool_removed, _id, coordinate, _reason}, state) do
    name = module_name(coordinate)

    case Map.get(state.names, name) do
      ^coordinate -> {:noreply, %{state | names: Map.delete(state.names, name)}}
      _ -> {:noreply, state}
    end
  end

  @impl true
  def handle_call({:resolve, name}, _from, state) do
    reply =
      case Map.fetch(state.names, name) do
        {:ok, coordinate} -> {:ok, coordinate, state.policy, state.timeout_ms}
        :error -> {:error, {:unknown_tool, name}}
      end

    {:reply, reply, state}
  end

  # The name is a lossy function of the coordinate: `a.b_c` and `a.b.c`
  # collide, and so would anything mDNS or the tuple space announced to
  # collide with a name a policy already uses. A name keeps its first
  # coordinate until that coordinate leaves. Also warned about: a name the
  # lexer cannot read, which is bound and unreachable.
  defp bind(state, coordinate) do
    name = module_name(coordinate)

    case Map.get(state.names, name) do
      nil ->
        unless lexable?(name) do
          Logger.warning(
            "[llmagent] #{coordinate} would be #{name}, which an Anemos policy cannot write"
          )
        end

        register(state.runtime, name)
        %{state | names: Map.put(state.names, name, coordinate)}

      ^coordinate ->
        state

      holder ->
        Logger.warning(
          "[llmagent] #{coordinate} would be #{name}, which #{holder} already is in " <>
            "#{state.runtime}; the newcomer is not reachable from policy"
        )

        state
    end
  end

  defp register(runtime, name) do
    case Anemos.Runtime.register(runtime, name, __MODULE__) do
      :ok ->
        :ok

      {:error, {:already_registered, other}} ->
        Logger.warning(
          "[llmagent] #{name} is bound to #{inspect(other)} in #{runtime}; " <>
            "the tool is not reachable under that name"
        )
    end
  end

  # What `Anemos.Lexer` reads as a module id: uppercase segments joined by
  # underscores, optionally ending in one lowercase segment.
  defp lexable?(name),
    do: Regex.match?(~r/^[A-Z][A-Z0-9]*(_[A-Z0-9]+)*(_[a-z][a-z0-9_-]*)?$/, name)

  # --- the verb ---

  @impl Anemos.Runtime.Module
  def handle_verb(verb, args, %{_module: name, _runtime: runtime}) do
    with {:ok, coordinate, policy, timeout_ms} <- resolve(runtime, name),
         {:ok, arg_map} <- pairs(args),
         {:ok, ad} <- Discovery.find_one(ToolQuery.new(%{coordinate: coordinate})) do
      isolated(fn -> call(ad, verb, arg_map, policy) end, timeout_ms)
    end
  end

  def handle_verb(_verb, _args, _context), do: {:error, :not_in_a_runtime}

  defp resolve(runtime, name) do
    GenServer.call(name_for(runtime), {:resolve, name})
  catch
    :exit, _ -> {:error, :detached}
  end

  defp pairs(args) do
    if rem(length(args), 2) == 0 do
      args
      |> Enum.chunk_every(2)
      |> Enum.reduce_while({:ok, %{}}, fn
        [key, value], {:ok, acc} when is_binary(key) -> {:cont, {:ok, Map.put(acc, key, value)}}
        _, _ -> {:halt, {:error, :args_must_be_key_value_pairs}}
      end)
    else
      {:error, :args_must_be_key_value_pairs}
    end
  end

  # The tool runs in a process that is not linked to the dispatcher and is
  # killed at the deadline. Its answer comes back as a message. An
  # exception is caught in that process, not reported by it: a crash
  # report would put the exception's message — whatever the tool said
  # about its arguments — in the log. Only the exception's module comes
  # back.
  defp isolated(fun, timeout_ms) do
    parent = self()
    tag = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            fun.()
          rescue
            exception -> {:error, {:tool_crashed, exception.__struct__}}
          catch
            kind, _reason -> {:error, {:tool_crashed, kind}}
          end

        send(parent, {tag, result})
      end)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:tool_crashed, crash_tag(reason)}}
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        {:error, :timeout}
    end
  end

  defp crash_tag({%{__struct__: exception}, _stack}), do: exception
  defp crash_tag({tag, _}) when is_atom(tag), do: tag
  defp crash_tag(tag) when is_atom(tag), do: tag
  defp crash_tag(_other), do: :exit

  defp call(%ToolAd{kinds: kinds} = ad, verb, args, policy) do
    @kind_order
    |> Enum.filter(&(&1 in kinds))
    |> Enum.reduce_while({:error, :kind_not_supported}, fn kind, _last ->
      case dispatch(kind, ad, verb, args, policy) do
        {:error, reason} when reason in [:unknown_action, :kind_not_supported] ->
          {:cont, {:error, reason}}

        {:ok, value, _meta_or_provenance} ->
          {:halt, {:ok, value}}

        other ->
          {:halt, verb_result(other)}
      end
    end)
  end

  # A verb answers `{:ok, _}` or `{:error, _}` and nothing else; the
  # dispatcher's `{:error, :forbidden, reason}` and whatever a tool returns
  # are folded into that shape.
  defp verb_result({:ok, _} = ok), do: ok
  defp verb_result({:error, _} = error), do: error
  defp verb_result({:error, tag, reason}), do: {:error, {tag, reason}}
  defp verb_result(other), do: {:error, {:unexpected_result, other}}

  defp dispatch(:query, ad, verb, args, policy),
    do: Dispatcher.query(ad, verb, args, policy: policy)

  defp dispatch(:compute, ad, verb, args, policy),
    do: Dispatcher.compute(ad, verb, args, policy: policy)

  defp dispatch(:generate, ad, verb, args, policy),
    do: Dispatcher.generate(ad, verb, args, policy: policy)

  defp dispatch(:action, ad, verb, args, policy),
    do: Dispatcher.act(ad, verb, args, nil, policy: policy)
end

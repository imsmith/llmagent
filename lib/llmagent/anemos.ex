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
  """

  use GenServer

  require Logger

  alias LLMAgent.{ToolAd, ToolQuery, Tool.Dispatcher, Tool.Policy, Tools.Discovery}

  @behaviour Anemos.Runtime.Module

  # Side-effect-free kinds first. A kind that does not know the action
  # yields to the next; the first answer that is not that is the answer.
  @kind_order [:query, :compute, :generate, :action]

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
  required), `:policy` (a `%LLMAgent.Tool.Policy{}`; default denies all).
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

  @doc "Every verb a policy could call, with what the ad says about it."
  @spec verbs() :: [verb()]
  def verbs do
    {:ok, ads} = Discovery.find_all(ToolQuery.new(%{coordinate: "*"}))

    for ad <- Enum.sort_by(ads, & &1.coordinate),
        action <- ad.operational |> Map.get(:actions, %{}) |> Map.keys() |> Enum.sort() do
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

  # --- server ---

  @impl true
  def init(opts) do
    runtime = Keyword.fetch!(opts, :runtime)
    policy = Keyword.get(opts, :policy, %Policy{})

    # The verb runs in the dispatcher's process, with only the context to go
    # on; the policy and the name-to-coordinate map are read from here.
    :persistent_term.put({__MODULE__, runtime, :policy}, policy)
    :persistent_term.put({__MODULE__, runtime, :coordinates}, %{})

    everything = ToolQuery.new(%{coordinate: "*"})
    :ok = Discovery.subscribe(everything, self())
    {:ok, ads} = Discovery.find_all(everything)
    Enum.each(ads, &register(runtime, &1.coordinate))

    {:ok, %{runtime: runtime}}
  end

  @impl true
  def handle_info({event, _id, coordinate}, state) when event in [:tool_added, :tool_updated] do
    register(state.runtime, coordinate)
    {:noreply, state}
  end

  def handle_info({:tool_removed, _id, _coordinate, _reason}, state), do: {:noreply, state}

  defp register(runtime, coordinate) do
    name = module_name(coordinate)
    key = {__MODULE__, runtime, :coordinates}
    :persistent_term.put(key, Map.put(:persistent_term.get(key), name, coordinate))

    case Anemos.Runtime.register(runtime, name, __MODULE__) do
      :ok ->
        :ok

      {:error, {:already_registered, other}} ->
        Logger.warning(
          "[llmagent] #{name} (#{coordinate}) is bound to #{inspect(other)} in #{runtime}; " <>
            "the tool is not reachable under that name"
        )
    end
  end

  # --- the verb ---

  @impl Anemos.Runtime.Module
  def handle_verb(verb, args, %{_module: name, _runtime: runtime}) do
    coordinate = Map.get(:persistent_term.get({__MODULE__, runtime, :coordinates}, %{}), name)
    policy = :persistent_term.get({__MODULE__, runtime, :policy}, %Policy{})

    with {:ok, coordinate} <- coordinate_for(coordinate, name),
         {:ok, arg_map} <- pairs(args),
         {:ok, ad} <- Discovery.find_one(ToolQuery.new(%{coordinate: coordinate})) do
      call(ad, verb, arg_map, policy)
    end
  end

  def handle_verb(_verb, _args, _context), do: {:error, :not_in_a_runtime}

  defp coordinate_for(nil, name), do: {:error, {:unknown_tool, name}}
  defp coordinate_for(coordinate, _name), do: {:ok, coordinate}

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

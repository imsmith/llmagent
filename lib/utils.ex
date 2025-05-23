defmodule LLMAgent.Utils do
  @moduledoc """
  Registry and dispatcher for pluggable utility modules.

  Mirrors the Tool behavior, allowing listing and dynamic execution.
  """

  @type util_name :: :encoder | :decoder

  alias LLMAgent.Utils.{
    Encoder,
    Decoder,
    RequireBinary,
    Time
  }

  @spec encoder :: module()
  def encoder, do: Encoder

  @spec decoder :: module()
  def decoder, do: Decoder

  @spec require_binary :: module()
  def require_binary, do: RequireBinary

  @spec time :: module()
  def time, do: Time

  @spec all() :: [{util_name(), module()}]
  def all do
    [
      encoder: encoder(),
      decoder: decoder(),
      require_binary: require_binary(),
      time: time()
    ]
  end

  @spec call(util_name(), String.t(), map()) :: {:ok, any()} | {:error, any()}
  def call(name, action, args) do
    case Map.get(Map.new(all()), name) do
      nil -> {:error, :unknown_util}
      mod -> mod.call(action, args)
    end
  end
end

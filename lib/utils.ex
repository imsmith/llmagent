defmodule LLMAgent.Utils do
  @moduledoc """
  Registry and dispatcher for pluggable utility modules.

  ## Examples

      iex> LLMAgent.Utils.encoder()
      LLMAgent.Utils.Encoder

      iex> LLMAgent.Utils.all() |> Keyword.keys()
      [:encoder, :decoder, :require_binary, :time]
  """

  @type util_name :: :encoder | :decoder

  alias LLMAgent.Utils.{
    Encoder,
    Decoder,
    RequireBinary,
    Time
  }

  @doc "Returns the Encoder utility module."
  @spec encoder :: module()
  def encoder, do: Encoder

  @doc "Returns the Decoder utility module."
  @spec decoder :: module()
  def decoder, do: Decoder

  @doc "Returns the RequireBinary utility module."
  @spec require_binary :: module()
  def require_binary, do: RequireBinary

  @doc "Returns the Time utility module."
  @spec time :: module()
  def time, do: Time

  @doc """
  Returns all available utilities as a keyword list.

  ## Examples

      iex> LLMAgent.Utils.all() |> Keyword.get(:encoder)
      LLMAgent.Utils.Encoder
  """
  @spec all() :: [{util_name(), module()}]
  def all do
    [
      encoder: encoder(),
      decoder: decoder(),
      require_binary: require_binary(),
      time: time()
    ]
  end

  @doc """
  Dispatch a call to a named utility.

  ## Examples

      iex> {:ok, encoded} = LLMAgent.Utils.call(:encoder, "base16", %{"data" => "hi"})
      iex> encoded
      "6869"

      iex> {:error, :unknown_util} = LLMAgent.Utils.call(:nope, "x", %{})
  """
  @spec call(util_name(), String.t(), map()) :: {:ok, any()} | {:error, any()}
  def call(name, action, args) do
    case Map.get(Map.new(all()), name) do
      nil -> {:error, :unknown_util}
      mod -> mod.call(action, args)
    end
  end
end

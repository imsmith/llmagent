defmodule LLMAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :LLMAgent,
      version: "0.2.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {LLMAgent.Application, []}
    ]
  end

  defp deps do
    [
      {:mix_test_watch, "~> 1.1", only: [:dev], runtime: false},
      {:req, "~> 0.5.0"},
      {:jason, "~> 1.4"},
      {:b58, "~> 1.0"},
      {:errors, path: "../comn/apps/errors"},
      {:events, path: "../comn/apps/events"}
    ]
  end
end

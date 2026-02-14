defmodule LLMAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :LLMAgent,
      version: "0.3.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        llmagent: [
          applications: [LLMAgent: :permanent]
        ]
      ]
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
      {:comn, github: "imsmith/comn", tag: "v0.3.0"}
    ]
  end
end

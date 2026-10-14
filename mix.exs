defmodule LLMAgent.MixProject do
  @moduledoc false

  use Mix.Project

  def project do
    [
      app: :LLMAgent,
      version: "0.3.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
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

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:mix_test_watch, "~> 1.1", only: [:dev], runtime: false},
      {:bandit, "~> 1.8", only: :test},
      {:telemetry_test, "~> 0.1", only: :test},
      {:plug, "~> 1.16", only: [:test]},
      {:req, "~> 0.7"},
      {:jason, "~> 1.4"},
      {:b58, "~> 1.0"},
      {:ex_edn, github: "imsmith/ex_edn", tag: "v0.1.0"},
      {:anemos, github: "imsmith/anemos"},
      {:comn, github: "imsmith/comn", tag: "v0.6.3"}
    ]
  end
end

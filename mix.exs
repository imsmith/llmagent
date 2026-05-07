defmodule LLMAgent.MixProject do
  @moduledoc false

  use Mix.Project

  def project do
    [
      app: :LLMAgent,
      version: "0.3.0",
      elixir: "~> 1.16",
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
      {:plug, "~> 1.16", only: [:test]},
      {:req, "~> 0.5.0"},
      {:jason, "~> 1.4"},
      {:b58, "~> 1.0"},
      {:eden, "~> 2.1"},
      {:comn, github: "imsmith/comn", tag: "v0.4.0"}
    ]
  end
end

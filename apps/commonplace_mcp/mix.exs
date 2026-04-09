defmodule Commonplace.MCP.MixProject do
  use Mix.Project

  def project do
    [
      app: :commonplace_mcp,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp escript do
    [main_module: Commonplace.MCP]
  end

  defp deps do
    [
      {:commonplace, in_umbrella: true},
      {:jason, "~> 1.4"}
    ]
  end
end

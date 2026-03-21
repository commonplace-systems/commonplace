defmodule Commonplace.MixProject do
  use Mix.Project

  def project do
    [
      app: :commonplace,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Commonplace.Application, []}
    ]
  end

  defp deps do
    [
      {:yelixer, in_umbrella: true},
      {:phoenix_pubsub, "~> 2.1"},
      {:cubdb, "~> 2.0"},
      {:uuid, "~> 1.1"}
    ]
  end
end

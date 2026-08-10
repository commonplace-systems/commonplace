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
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_clean: ["clean"],
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :xmerl],
      mod: {Commonplace.Application, []}
    ]
  end

  defp deps do
    [
      {:yelixer, in_umbrella: true},
      {:phoenix_pubsub, "~> 2.1"},
      {:cubdb, "~> 2.0"},
      {:uuid, "~> 1.1"},
      {:file_system, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:req, "~> 0.5"},
      {:elixir_make, "~> 0.9", runtime: false},
      {:libcluster, "~> 3.3"}
    ]
  end
end

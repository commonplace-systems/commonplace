defmodule Commonplace.Bots.MixProject do
  use Mix.Project

  def project do
    [
      app: :commonplace_bots,
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
      mod: {Commonplace.Bots.Application, []}
    ]
  end

  defp deps do
    [
      {:commonplace, in_umbrella: true},
      {:jason, "~> 1.4"},
      # HTTP client for the Anthropic Messages API. Req on top of
      # Finch (Finch is already a transitive via anubis_mcp), so the
      # marginal weight is small.
      {:req, "~> 0.5"}
    ]
  end
end

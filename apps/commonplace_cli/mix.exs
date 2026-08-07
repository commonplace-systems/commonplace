defmodule Commonplace.CLI.MixProject do
  use Mix.Project

  def project do
    [
      app: :commonplace_cli,
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
    [
      main_module: Commonplace.CLI,
      # The CLI decides deliberately whether to route to a serve or boot
      # :commonplace locally. Letting Mix's generated escript wrapper start
      # the project app would recursively start :commonplace against the
      # compile-time default data dir ("data") before argument parsing.
      app: nil,
      # Native libraries are not included for dependencies unless named.
      # EscriptNif extracts this entry onto a real filesystem before Flock's
      # on_load callback runs.
      include_priv_for: [:commonplace]
    ]
  end

  defp deps do
    [
      {:commonplace, in_umbrella: true}
    ]
  end
end

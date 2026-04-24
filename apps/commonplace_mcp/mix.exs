defmodule Commonplace.MCP.MixProject do
  use Mix.Project

  def project do
    [
      app: :commonplace_mcp,
      version: "0.2.0",
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
      {:jason, "~> 1.4"},
      # CX-pd6k: anubis_mcp is the active Elixir MCP library tracking
      # three protocol versions and implementing the rare features
      # (sampling, elicitation, completion, session resumption). We
      # vendor it behind the `Commonplace.MCP.*` namespace so all
      # callers depend on our wrappers, not on anubis types directly
      # — a future fork swap touches the facade, not every caller.
      # LGPL-3.0; survivable as a library dep, flag if commonplace
      # ever ships statically into proprietary distro.
      {:anubis_mcp, "~> 1.1"}
    ]
  end
end

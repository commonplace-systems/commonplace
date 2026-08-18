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

  # THE CORE-SEAM BUILD (S1 ratchet, CX-27vt; ruled ratchet-with-declared-
  # exclusions). :coreseam compiles the extractable CORE — everything below
  # the filesystem seam — by excluding sync/, process/, the above-seam
  # subsystems that legitimately depend on them (git_bridge, federation,
  # cluster, reflog, runner), and the composition root (application.ex,
  # which references the whole world by design). bin/cp-core-seam compiles
  # this set and gates on the DECLARED debt list it carries — see that
  # script for the three known core->sync references and the rules that
  # make the list shrink-only. ⛔ Do not add a directory here to silence a
  # seam warning: that is the coupling the ratchet exists to stop.
  defp elixirc_paths(:coreseam) do
    # cell/ rides above with runner: LaunchAct pattern-matches the
    # %Runner.ExecutorProfile{} struct (the §4b refusal clause), a
    # compile-time dependency the first seam build surfaced.
    above_seam = ~w(sync process git_bridge federation cluster reflog runner cell)

    # proto_chit rides above too: the chit tap is cell-track machinery and
    # calls Sync.Watcher and Reflog.Snapshot/Restore by design (five upward
    # references, surfaced by the first seam build).
    above_seam_files = ~w(application.ex cluster.ex proto_chit.ex)

    lib_entries =
      "lib/commonplace"
      |> File.ls!()
      |> Enum.reject(&(&1 in above_seam or &1 in above_seam_files))
      |> Enum.map(&("lib/commonplace/" <> &1))

    ["lib/commonplace.ex" | lib_entries]
  end

  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :xmerl],
      mod: {Commonplace.Application, []}
    ]
  end

  defp deps do
    [
      {:yelixer, git: "https://github.com/commonplace-systems/yelixer.git", ref: "bc35a0e9"},
      {:phoenix_pubsub, "~> 2.1"},
      {:cubdb, "~> 2.0"},
      {:uuid, "~> 1.1"},
      {:file_system, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:req, "~> 0.5"},
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.0"},
      {:elixir_make, "~> 0.9", runtime: false},
      {:libcluster, "~> 3.3"}
    ]
  end
end

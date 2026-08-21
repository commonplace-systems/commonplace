defmodule Mix.Tasks.Commonplace.MixedPlaneScan do
  use Mix.Task

  # ⛔ WITHOUT THIS, `mix <this task>` EXECUTES WHATEVER BEAMS _build ALREADY
  # HOLDS — it never recompiles. Demonstrated live 2026-08-21 (boss #14448):
  # pass 3 of the (a) migration ran a 41-minute-stale DocCommitBackfill.beam
  # and re-died on the bug the working tree had already fixed. Touch-probe
  # confirmed: source touched, task run, beam mtime unchanged. Every task in
  # this directory carries this line; a test pins the family.
  @requirements ["compile"]

  @shortdoc "Scan every persisted document commit for mixed-plane history"

  @moduledoc """
  Runs the mandatory positive-control gate and a resumable mixed-plane
  history sweep.

      mix commonplace.mixed_plane_scan --node commonplace_dev@commonplace \
        --checkpoint /tmp/mixed-plane-scan

  When the serve's short hostname needs the repository's loopback mapping,
  start Mix with `ERL_INETRC=bin/erl_inetrc`; the VM reads that setting at
  boot, before this task can configure distribution.

  The production form makes exactly one `:erpc` call: the complete gate and
  sweep execute inside the serve. Killing this Mix client does not reap that
  remote work. To stop safely, create `STOP` in the checkpoint directory;
  the serve finishes in-flight documents, checkpoints them, and exits the
  sweep nonzero. Remove `STOP` before resuming. `--fixture` performs a local dry
  run using only scratch CubDB stores under `/tmp`; it never starts
  distribution or contacts a serve.

  Oracle reconstruction is the default because it was faster on the live
  workload: 162.7 seconds versus 231.9 seconds for incremental across 25
  documents and 56 commits (2.24 commits/document). Incremental was 0.70x as
  fast, or 1.43x slower, but remains opt-in because it wins on deep chains
  (9.8x on a 200-commit chain).

  Commit enumeration walks the complete commit key range once and groups IDs
  by document before reconstruction begins. It does not derive IDs from
  `:latest`, so persisted unreachable siblings remain in the sweep.

  Options:

    * `--node NODE` - target serve node (required except with `--fixture`)
    * `--checkpoint PATH` - resumability checkpoint directory (required)
    * `--progress-every N` - progress cadence in documents (default 1)
    * `--max-concurrency N` - documents scanned concurrently (default 4)
    * `--incremental` - use the memoized-parent walk instead of the default oracle
    * `--fixture` - local five-commit dry run; never contacts real data
  """

  alias Commonplace.Projection.{MixedPlaneHistory, MixedPlaneHistoryFixture}

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          node: :string,
          checkpoint: :string,
          progress_every: :integer,
          max_concurrency: :integer,
          fixture: :boolean,
          incremental: :boolean
        ]
      )

    if rest != [] or invalid != [], do: usage!("invalid arguments")

    checkpoint = opts[:checkpoint] || usage!("--checkpoint is required")

    scanner_opts = [
      checkpoint_path: checkpoint,
      progress_every: opts[:progress_every] || 1,
      max_concurrency: opts[:max_concurrency] || 4,
      scan_strategy: if(opts[:incremental], do: :incremental, else: :oracle)
    ]

    result =
      if opts[:fixture] do
        fixture_run(scanner_opts)
      else
        node_name = opts[:node] || usage!("--node is required unless --fixture is used")
        remote_run(node_name, scanner_opts)
      end

    case result do
      {:ok, _summary} -> :ok
      {:error, reason} -> Mix.raise("mixed-plane scan failed: #{inspect(reason)}")
      other -> Mix.raise("mixed-plane scan returned an invalid result: #{inspect(other)}")
    end
  end

  defp fixture_run(opts) do
    {:ok, _started} = Application.ensure_all_started(:telemetry)

    MixedPlaneHistoryFixture.with_store(fn store, _fixture ->
      MixedPlaneHistory.run(
        Keyword.merge(opts,
          mode: :fixture,
          store: store,
          scan_id: "fixture-five-commit-history"
        )
      )
    end)
  end

  defp remote_run(node_name, opts) do
    serve_node = String.to_atom(node_name)
    host = node_name |> String.split("@", parts: 2) |> List.last()

    :application.set_env(:kernel, :prevent_overlapping_partitions, false)
    :application.set_env(:kernel, :inet_dist_use_interface, {127, 0, 0, 1})
    probe = String.to_atom("mixed_plane_probe_#{System.unique_integer([:positive])}@#{host}")

    with {:ok, _pid} <- Node.start(probe, :shortnames),
         true <- Node.connect(serve_node) do
      :erpc.call(
        serve_node,
        MixedPlaneHistory,
        :run,
        [Keyword.put(opts, :mode, :live)],
        :infinity
      )
    else
      false -> {:error, {:node_connect_failed, serve_node}}
      {:error, reason} -> {:error, {:probe_start_failed, reason}}
    end
  end

  defp usage!(message) do
    Mix.raise(
      "#{message}\nusage: mix commonplace.mixed_plane_scan " <>
        "--checkpoint PATH [--fixture | --node NODE] " <>
        "[--progress-every N] [--max-concurrency N] [--incremental]\n" <>
        "default strategy: oracle (162.7s vs 231.9s incremental at 2.24 commits/doc); " <>
        "the ~10h sweep is dominated by CX-3an0 commit enumeration, not reconstruction"
    )
  end
end

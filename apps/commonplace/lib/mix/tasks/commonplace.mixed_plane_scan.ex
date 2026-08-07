defmodule Mix.Tasks.Commonplace.MixedPlaneScan do
  use Mix.Task

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
  sweep execute inside the serve. `--fixture` instead performs a local dry
  run using only scratch CubDB stores under `/tmp`; it never starts
  distribution or contacts a serve.

  Options:

    * `--node NODE` - target serve node (required except with `--fixture`)
    * `--checkpoint PATH` - resumability checkpoint directory (required)
    * `--progress-every N` - progress cadence in documents (default 25)
    * `--max-concurrency N` - documents scanned concurrently (default 4)
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
          fixture: :boolean
        ]
      )

    if rest != [] or invalid != [], do: usage!("invalid arguments")

    checkpoint = opts[:checkpoint] || usage!("--checkpoint is required")

    scanner_opts = [
      checkpoint_path: checkpoint,
      progress_every: opts[:progress_every] || 25,
      max_concurrency: opts[:max_concurrency] || 4
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
        "[--progress-every N] [--max-concurrency N]"
    )
  end
end

defmodule Mix.Tasks.Commonplace.AuditCommitPopulation do
  use Mix.Task

  @shortdoc "World-B: audit the commit population vs the {:latest}/{:doc_commit} indexes (STOPPED serve)"

  @moduledoc """
  World-B `:commit` full-population audit (plan #13407) — the independent
  instrument that catches `all_doc_uuids` (`{:latest,_}`) UNDER-enumerating the
  true document population, which the §4 coverage gate structurally cannot.
  See `Commonplace.Store.CommitPopulationAudit` and the design doc
  `docs/plans/2026-08-21-world-b-commit-population-audit-design.md`.

  ## Run model — STOPPED serve, host-gated (same ceremony as §3 backfill)

  Run model (b): a SEPARATE process that opens the STOPPED serve's `data_dir` as
  the sole flock holder — NOT an erpc into the live serve (the enumerators are
  not resident on the behind serve; erpc'ing them would force-load working-tree
  code = a WRITE, and a live scan straddles concurrent writes → a transient false
  orphan). Launch under `systemd-run --user --unit=<name>` with an enforced
  `MemoryMax` and `OOMScoreAdjust=900`, so the O(store) unbounded scan is bounded
  and a kill hits THIS unit, never the (down) live serve:

      systemd-run --user --unit=cp-world-b \\
        -p MemoryMax=6G -p OOMScoreAdjust=900 -p MemorySwapMax=0 \\
        mix commonplace.audit_commit_population \\
          --data-dir /home/jes/commonplace/workspace/.commonplace \\
          --unit cp-world-b --expected-bytes 6442450944 \\
          --expected-oom-adj 900 \\
          --out /home/jes/commonplace/.commonplace-state/world-b-audit.json

  ⚠️ `--data-dir` is the PARENT of the store (`CommitStore.init/1` appends
  `/commits`); pass `.../.commonplace`, not `.../.commonplace/commits`. The
  non-vacuity gate refuses a wrong path rather than CREATE-on-open an empty store.
  The ①-ceiling QUAD (MemoryMax + LoadState + ActiveState + effective
  oom_score_adj) and the non-vacuity gate are the SAME tested logic as §3's
  backfill task; this task reuses those public functions rather than re-deriving.

  ## The artifact is the verdict — durable, re-verdictable

  The full report (population sizes + every diff's members) is written to `--out`
  as JSON so the verdict outlives the moving store and can be re-checked later
  (boss #13836's transient-observable → capture law). Commit ids (raw binaries)
  are hex-encoded; doc uuids are strings. This is a REPORT read when the audit
  runs, NOT a standing alarm: the task exits 0 even on a non-green verdict (real
  orphans found is a valid report result), but logs the verdict at `:error` when
  not green so it is loud in the log, and REFUSES (raises) only on a VACUOUS run
  (the audit examined nothing — a corpus positive-control failure, not a verdict).

  Options:
    * `--data-dir PATH` (required) — the store's PARENT dir (init appends /commits)
    * `--unit NAME` (required) — this task's own systemd unit, to verify ①
    * `--out PATH` (required) — where to write the durable JSON artifact
    * `--expected-bytes N` — assert `MemoryMax == N` exactly
    * `--expected-oom-adj N` — assert effective `oom_score_adj == N` exactly
    * `--min-store-bytes N` — override the non-vacuity floor (default 1_000_000)
  """

  alias Commonplace.Store.{CommitPopulationAudit, CommitStore}
  alias Mix.Tasks.Commonplace.BackfillAcceptedHeads, as: Ceremony
  require Logger

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          data_dir: :string,
          unit: :string,
          out: :string,
          expected_bytes: :integer,
          expected_oom_adj: :integer,
          min_store_bytes: :integer
        ]
      )

    data_dir =
      opts[:data_dir] ||
        Mix.raise("--data-dir is required (the STOPPED serve's commits data_dir, its PARENT)")

    unit =
      opts[:unit] ||
        Mix.raise("--unit is required: a run without a verified enforced ceiling is refused (①)")

    out =
      opts[:out] ||
        Mix.raise("--out is required: the audit's value is the DURABLE artifact it writes")

    {:ok, _} = Application.ensure_all_started(:telemetry)

    # ① ceiling QUAD — reuse §3's tested ceremony (identical host-safety contract).
    verify_ceiling!(unit, opts[:expected_bytes])
    verify_oom_adj!(opts[:expected_oom_adj])

    # Non-vacuity gate BEFORE start_link (never create the empty store we guard against).
    min_bytes = opts[:min_store_bytes] || 1_000_000

    case Ceremony.check_non_vacuous(data_dir, min_bytes) do
      {:ok, store_dir, cub_bytes} ->
        Logger.info(
          "World-B non-vacuity gate PASSED: #{store_dir} holds #{cub_bytes} bytes of .cub"
        )

      {:error, {:no_store, store_dir}} ->
        Mix.raise(
          "no store at #{store_dir}: CommitStore appends /commits to --data-dir, so pass the " <>
            "PARENT. Refusing to CREATE-on-open and 'audit' a store that never existed."
        )

      {:error, {:vacuous, store_dir, cub_bytes, min}} ->
        Mix.raise(
          "store at #{store_dir} holds only #{cub_bytes} bytes of .cub (< #{min}): empty or a " <>
            "wrong-path store created on open. Refusing a vacuous audit. Pass --min-store-bytes " <>
            "for a legitimately small store."
        )
    end

    name = :world_b_audit_store
    {:ok, _pid} = CommitStore.start_link(data_dir: data_dir, name: name)

    report = CommitPopulationAudit.check(name)

    # Write the durable artifact FIRST (evidence must outlive the run), THEN
    # decide loudness / refusal.
    write_artifact!(out, report, data_dir)
    Logger.info("World-B audit artifact written: #{out}")

    cond do
      report.vacuous ->
        # Corpus positive control: the store had bytes but the audit examined no
        # commits. That is a broken run, not a verdict — refuse (a run that
        # examined nothing produced nothing), the artifact having been captured.
        Mix.raise(
          "World-B audit is VACUOUS (p_doccommit=#{report.p_doccommit}, " <>
            "ids_from_structs=#{report.ids_from_structs}): the corpus positive control failed — " <>
            "a store with bytes but no commits. Artifact written to #{out}."
        )

      report.green ->
        Logger.info(
          "World-B audit GREEN — the commit population is fully covered by both indexes."
        )

      true ->
        Logger.error(
          "World-B audit NOT GREEN — index_ready=#{report.index_ready} " <>
            "orphaned_from_latest=#{length(report.orphaned_from_latest)} " <>
            "dangling_latest=#{length(report.dangling_latest)} " <>
            "commits_missing_from_doc_index=#{length(report.commits_missing_from_doc_index)} " <>
            "dangling_doc_index=#{length(report.dangling_doc_index)}. See #{out}."
        )
    end

    :ok
  end

  defp verify_ceiling!(unit, expected_bytes) do
    triple_output = systemctl_triple(unit)
    Logger.info("World-B ① ceiling triple (unit=#{unit}): #{String.trim(triple_output)}")

    case Ceremony.verify_ceiling(triple_output, expected_bytes) do
      {:ok, triple} ->
        Logger.info("World-B ① ceiling VERIFIED: #{inspect(triple)}")

      {:error, reason} ->
        Mix.raise(
          "World-B ① ceiling verification FAILED: #{inspect(reason)} — refusing to run without " <>
            "an enforced MemoryMax (a run without a ceiling is not a run)"
        )
    end
  end

  defp verify_oom_adj!(expected) do
    oom_adj =
      case File.read("/proc/self/oom_score_adj") do
        {:ok, content} -> String.trim(content)
        {:error, _} -> nil
      end

    Logger.info("World-B ① oom_score_adj (by effect, /proc/self): #{inspect(oom_adj)}")

    case Ceremony.verify_oom_adj(oom_adj, expected) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.raise(
          "World-B ① oom_score_adj verification FAILED: #{inspect(reason)} — refusing to run " <>
            "without the enforced kill-order knob (OOMScoreAdjust=900 makes the audit first-to-die)"
        )
    end
  end

  defp systemctl_triple(unit) do
    {out, _status} =
      System.cmd(
        "systemctl",
        ["--user", "show", unit, "-p", "MemoryMax", "-p", "LoadState", "-p", "ActiveState"],
        stderr_to_stdout: true
      )

    out
  end

  # The durable artifact. Commit-id lists are raw 32-byte binaries — hex-encode
  # them so the JSON is valid and human-legible; doc uuids are already strings.
  defp write_artifact!(out, report, data_dir) do
    payload = %{
      kind: "world-b-commit-population-audit",
      data_dir: data_dir,
      sizes: %{
        p_doccommit: report.p_doccommit,
        p_latest: report.p_latest,
        ids_from_structs: report.ids_from_structs,
        ids_from_doc_index: report.ids_from_doc_index
      },
      index_ready: report.index_ready,
      vacuous: report.vacuous,
      green: report.green,
      orphaned_from_latest: report.orphaned_from_latest,
      dangling_latest: report.dangling_latest,
      commits_missing_from_doc_index: Enum.map(report.commits_missing_from_doc_index, &hex/1),
      dangling_doc_index: Enum.map(report.dangling_doc_index, &hex/1)
    }

    File.mkdir_p!(Path.dirname(out))
    File.write!(out, Jason.encode!(payload, pretty: true) <> "\n")
  end

  defp hex(bin) when is_binary(bin), do: Base.encode16(bin, case: :lower)
end

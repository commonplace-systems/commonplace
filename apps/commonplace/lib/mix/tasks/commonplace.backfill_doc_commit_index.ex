defmodule Mix.Tasks.Commonplace.BackfillDocCommitIndex do
  use Mix.Task

  # ⛔ WITHOUT THIS, `mix <this task>` EXECUTES WHATEVER BEAMS _build ALREADY
  # HOLDS — it never recompiles. Demonstrated live 2026-08-21 (boss #14448):
  # pass 3 of the (a) migration ran a 41-minute-stale DocCommitBackfill.beam
  # and re-died on the bug the working tree had already fixed. Touch-probe
  # confirmed: source touched, task run, beam mtime unchanged. Every task in
  # this directory carries this line; a test pins the family.
  @requirements ["compile"]

  @shortdoc "The (a) round: backfill fork-lineage {:doc_commit} rows (run model (b), STOPPED serve)"

  @moduledoc """
  Backfills the missing `{:doc_commit, key_doc, commit_id}` membership rows
  for fork-lineage docs (the F2 116 — the World-B `dangling_latest` class),
  per the ratified brief `docs/plans/2026-08-21-doc-commit-backfill-brief.md`.
  The logic lives in `Commonplace.Store.DocCommitBackfill`; this task is the
  host-gated launcher, the BUILD-1 §3 run model verbatim: a SEPARATE process
  that opens the STOPPED serve's `data_dir` as the sole flock holder — NOT
  an erpc into the live serve.

      systemd-run --user --unit=cp-dc-backfill \\
        -p MemoryMax=6G -p OOMScoreAdjust=900 \\
        mix commonplace.backfill_doc_commit_index \\
          --data-dir /home/jes/commonplace/workspace/.commonplace \\
          --unit cp-dc-backfill --expected-bytes 6442450944 \\
          --expected-oom-adj 900 --out /path/to/report.txt

  ⚠️ `--data-dir` is the PARENT of the store, NOT the store itself
  (`CommitStore.init/1` appends `/commits`); the non-vacuity gate refuses
  the wrong-path empty store BEFORE it can be created. The ① ceiling quad
  (MemoryMax triple verified while active + `oom_score_adj` read by effect
  from `/proc/self`) is `Mix.Tasks.Commonplace.BackfillAcceptedHeads`'
  helpers, reused — one implementation, two launchers.

  The report's `backfilled` list is the processed ID SET for the World-B
  set-difference convergence check (acceptance 5): `dangling_pre \\
  dangling_post == backfilled` AND `dangling_post ∩ backfilled == ∅` —
  never a count-delta, which can mask an exchange. Write it with `--out`.

  Options:
    * `--data-dir PATH` (required) — the store's PARENT dir (init appends /commits)
    * `--unit NAME` (required) — this task's own systemd unit, to verify ①
    * `--expected-bytes N` — assert `MemoryMax == N` exactly
    * `--expected-oom-adj N` — assert effective `oom_score_adj == N` exactly
    * `--min-store-bytes N` — override the non-vacuity floor (default 1_000_000)
    * `--walk-budget N` — max commits walked per doc (default `max_commit_log_limit`)
    * `--put-chunk N` — rows per write call (default 2000; head row always in the LAST chunk)
    * `--out PATH` — write the full report (including the id sets) to a file
  """

  alias Commonplace.Store.{CommitStore, DocCommitBackfill}
  alias Mix.Tasks.Commonplace.BackfillAcceptedHeads, as: Gates
  require Logger

  @min_store_bytes 1_000_000

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          data_dir: :string,
          unit: :string,
          expected_bytes: :integer,
          expected_oom_adj: :integer,
          min_store_bytes: :integer,
          walk_budget: :integer,
          put_chunk: :integer,
          out: :string
        ]
      )

    data_dir =
      opts[:data_dir] ||
        Mix.raise("--data-dir is required (the STOPPED serve's commits data_dir)")

    unit =
      opts[:unit] ||
        Mix.raise("--unit is required: a run without a verified enforced ceiling is refused (①)")

    {:ok, _} = Application.ensure_all_started(:telemetry)

    # Code identity, logged by the RUN itself: pass 3 of the live migration
    # executed a 41-minute-stale beam and re-died on an already-fixed bug
    # (boss #14448). @requirements ["compile"] prevents the recurrence; this
    # line makes the precondition ARTIFACT-CHECKABLE — the operator compares
    # the logged md5 against the merged tree's compiled beam instead of
    # trusting mtimes (cp-verify-deploy's resident-digest pattern, run-side).
    backfill_md5 =
      Commonplace.Store.DocCommitBackfill.module_info(:md5) |> Base.encode16(case: :lower)

    Logger.info("(a) code identity: DocCommitBackfill md5=#{backfill_md5}")

    # ① ceiling triple + kill-order knob, via the §3 task's public helpers.
    triple_output = systemctl_triple(unit)
    Logger.info("(a) ① ceiling triple (unit=#{unit}): #{String.trim(triple_output)}")

    case Gates.verify_ceiling(triple_output, opts[:expected_bytes]) do
      {:ok, triple} ->
        Logger.info("(a) ① ceiling VERIFIED: #{inspect(triple)}")

      {:error, reason} ->
        Mix.raise(
          "(a) ① ceiling verification FAILED: #{inspect(reason)} — refusing to run " <>
            "without an enforced MemoryMax (a run without a ceiling is not a run)"
        )
    end

    oom_adj = read_oom_score_adj()
    Logger.info("(a) ① oom_score_adj (by effect, /proc/self): #{inspect(oom_adj)}")

    case Gates.verify_oom_adj(oom_adj, opts[:expected_oom_adj]) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.raise(
          "(a) ① oom_score_adj verification FAILED: #{inspect(reason)} — refusing to run " <>
            "without the enforced kill-order knob"
        )
    end

    min_bytes = opts[:min_store_bytes] || @min_store_bytes

    case Gates.check_non_vacuous(data_dir, min_bytes) do
      {:ok, store_dir, cub_bytes} ->
        Logger.info("(a) non-vacuity gate PASSED: #{store_dir} holds #{cub_bytes} bytes of .cub")

      {:error, {:no_store, store_dir}} ->
        Mix.raise(
          "no store at #{store_dir}: pass the PARENT dir (e.g. .../.commonplace, not " <>
            ".../.commonplace/commits). Refusing to CREATE-on-open and 'succeed' on a " <>
            "store that never existed."
        )

      {:error, {:vacuous, store_dir, cub_bytes, min}} ->
        Mix.raise(
          "store at #{store_dir} holds only #{cub_bytes} bytes of .cub (< #{min}): empty, " <>
            "or a wrong-path store created on open. Refusing a vacuous run."
        )
    end

    name = :doc_commit_backfill_store
    {:ok, _pid} = CommitStore.start_link(data_dir: data_dir, name: name)

    run_opts =
      Enum.reject(
        [walk_budget: opts[:walk_budget], put_chunk: opts[:put_chunk]],
        fn {_k, v} -> is_nil(v) end
      )

    case DocCommitBackfill.run(name, run_opts) do
      {:ok, report} ->
        maybe_write_out(opts[:out], report)
        Logger.info("(a) backfill report written; see log line above for the counts")
        :ok

      {:error, reason} ->
        Mix.raise("(a) backfill REFUSED: #{inspect(reason)}")
    end
  end

  defp maybe_write_out(nil, _report), do: :ok

  defp maybe_write_out(path, report) do
    File.write!(path, inspect(report, limit: :infinity, printable_limit: :infinity, pretty: true))
    Logger.info("(a) full report (including id sets) written to #{path}")
  end

  defp read_oom_score_adj do
    case File.read("/proc/self/oom_score_adj") do
      {:ok, content} -> String.trim(content)
      {:error, _} -> nil
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
end

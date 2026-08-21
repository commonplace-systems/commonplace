defmodule Mix.Tasks.Commonplace.CoverageCanary do
  use Mix.Task

  @shortdoc "BUILD-1 §4 step 2: read-only coverage canary against the LIVE serve"

  @moduledoc """
  BUILD-1 §4 step 2 — run the coverage gate READ-ONLY against the live serve,
  canary-first. The go/no-go is `AcceptedHeadsCoverage.verdict/1` and each
  entry is `AcceptedHeadsCoverage.build_entry/3` — both committed and tested
  (accepted_heads_coverage_test.exs). This task is the durable, compiled,
  CI-covered home for the probe (commonplace-coder #13861): a gate that
  authorizes an irreversible removal must outlive the session that ran it, and
  being compiled means a `build_entry`/`verdict` signature drift is a CI red,
  not a silent bitrot of a scratch script.

  ## Run (serve UP; from the commonplace checkout)

      ERL_INETRC=<inetrc> mix commonplace.coverage_canary \\
        --serve-pid $(ss -ltnp | ... the live serve's pid) --chunk 500

  `<inetrc>` maps the serve sname (see bin/cp-verify-deploy):

      {lookup,[file,native]}.
      {host,{127,0,0,1},["commonplace"]}.

  Options:
    * `--serve-pid N` (REQUIRED) — the live serve OS pid, for the RSS metric.
      NO default: a default pid is a fact that was true when it was typed
      (boss #13869); pass it from `ss -ltnp` at the moment of the run so the
      RSS figure cannot silently describe a different process.
    * `--serve-node NAME` — default `commonplace_dev@commonplace`.
    * `--chunk N` — canary chunk / full-run chunk size (default 500).
    * `--all` — full corpus, chunked at `--chunk` (default: canary — ONE chunk
      then HALT for review, boss #13850).
    * `--pace-ms N` — sleep between chunks in `--all` mode (default 0). The
      serve is serving; boss prefers paced over back-to-back.
    * `--out PATH` — capture file for entries + verdict (default under /tmp).

  ## What it satisfies (the ruled conditions)

    * Option B / no transcription (plan #13835): calls the tested
      `build_entry/3` + `verdict/1` on THIS node; the only task-specific code
      is two 1-line erpc READERS, whose failure is LOUD (erpc error →
      `{doc,nil,∅}` → reported missing → false RED, never a false green).
    * Non-perturbation (boss/paravel): `:code.is_loaded` per callee halts
      BEFORE any force-load, and before/after `:code.all_loaded` on the serve
      proves nothing loaded — a SEPARATE claim from correctness, both shown.
    * Telemetry pre-check (coder #13851): lists handlers on
      `[:commonplace,:commit,:latest_read]` before the reads (latest_commit
      emits per read); reports whose metric the reads would move.
    * Skew as a NUMBER (boss #13850): re-reads `missing` (pass 2) and reports
      pass1/pass2/SKEW — the live-serve two-read skew is a false RED only
      (never a false green), reported not absorbed.
    * Capture (boss #13836 / plan #13837): entries + verdict written to a file
      BEFORE the summary prints, so the decision is re-verdictable later.

  ## Numbers to read with care

    * `largest single commit` is a LOWER BOUND, not the corpus max: any
      500-of-6105 sample understates a maximum however random the draw — an
      order-statistic fact no sampling scheme fixes (paravel #13864 / coder
      #13868 / boss #13869). Mean-based figures (wall, total bytes) extrapolate
      fine — doc uuids are random v4, so the sorted sample is effectively
      uniform (NOT time-ordered; this is a property of THIS corpus). A handful
      of structured well-known uuids (e.g. the MUD root `a4f1be2a-0000-…`, v0)
      sort to fixed positions — too few to move the statistics, noted so the
      uniformity is not silently assumed.

  ## ⚠️ Accepted inefficiency, labelled on purpose (boss #13852)

  To read one id per doc this ships the FULL latest commit per doc, because
  `latest_commit` is the only RESIDENT reader of the `{:latest,_}` pointer (a
  one-pass reader returning just `{latest_id, heads}` is ~3 lines but not
  deployed; reaching it needs a serve restart, declined for a read-only gate).
  ONE-TIME, bounded, accepted for THIS gate. ⛔ DO NOT copy "fetch full commits
  to read ids" into a recurring job — the arithmetic is not the same. The owed
  World-B `:commit` standing audit should use the one-pass reader.
  """

  alias Commonplace.Store.{AcceptedHeadsCoverage, CommitStore}

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          serve_pid: :string,
          serve_node: :string,
          chunk: :integer,
          all: :boolean,
          pace_ms: :integer,
          out: :string
        ]
      )

    serve_pid =
      opts[:serve_pid] ||
        Mix.raise(
          "--serve-pid is REQUIRED (the live serve OS pid, from `ss -ltnp` at run time; " <>
            "a default pid is a fact that was true when it was typed)"
        )

    serve = String.to_atom(opts[:serve_node] || "commonplace_dev@commonplace")
    chunk = opts[:chunk] || 500
    pace_ms = opts[:pace_ms] || 0
    all? = opts[:all] || false
    out = opts[:out] || "/tmp/section4-coverage-#{serve_pid}.capture"

    :application.set_env(:kernel, :prevent_overlapping_partitions, false)
    :application.set_env(:kernel, :inet_dist_use_interface, {127, 0, 0, 1})
    me = :"s4_coverage_#{:erlang.unique_integer([:positive])}@commonplace"

    case Node.start(me, :shortnames) do
      {:ok, _} -> :ok
      {:error, r} -> Mix.raise("probe node start failed: #{inspect(r)}")
    end

    unless Node.connect(serve), do: Mix.raise("connect failed: #{inspect(serve)}")
    erpc = fn m, f, a -> :erpc.call(serve, m, f, a, 60_000) end

    for mod <- [CommitStore, :telemetry] do
      unless match?({:file, _}, erpc.(:code, :is_loaded, [mod])) do
        Mix.raise(
          "#{inspect(mod)} not resident on the serve — calling it would force-load our tree (a write). Aborting."
        )
      end
    end

    loaded_before = erpc.(:code, :all_loaded, []) |> length()
    handlers = erpc.(:telemetry, :list_handlers, [[:commonplace, :commit, :latest_read]])
    IO.puts("telemetry handlers on [:commonplace,:commit,:latest_read]: #{length(handlers)}")

    if handlers != [] do
      IO.puts(
        "⚠️ latest_read has #{length(handlers)} handler(s): #{inspect(Enum.map(handlers, & &1[:id]))} — the latest_commit reads WILL fire events into them (metric contamination). Reporting, not aborting."
      )
    end

    all_docs = erpc.(CommitStore, :all_doc_uuids, []) |> MapSet.to_list() |> Enum.sort()
    total = length(all_docs)
    scope_docs = if all?, do: all_docs, else: Enum.take(all_docs, chunk)

    rss = fn -> read_rss(serve_pid) end
    rss_before = rss.()

    {elapsed_us, fetched} =
      :timer.tc(fn -> fetch_chunked(scope_docs, chunk, pace_ms, erpc) end)

    rss_after = rss.()

    entries = Enum.map(fetched, &elem(&1, 0))
    report = AcceptedHeadsCoverage.verdict(entries)

    still_missing =
      report.missing
      |> Enum.map(fn doc -> elem(fetch_one(doc, erpc), 0) end)
      |> AcceptedHeadsCoverage.verdict()
      |> Map.get(:missing)

    skew = length(report.missing) - length(still_missing)
    transfer_total = fetched |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    transfer_max = fetched |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)
    loaded_after = erpc.(:code, :all_loaded, []) |> length()

    write_capture(out, all?, chunk, total, report, skew, still_missing, entries)

    print_report(%{
      all?: all?,
      scope_n: length(scope_docs),
      total: total,
      elapsed_us: elapsed_us,
      transfer_total: transfer_total,
      transfer_max: transfer_max,
      rss_before: rss_before,
      rss_after: rss_after,
      report: report,
      first_missing: length(report.missing),
      still_missing: length(still_missing),
      skew: skew,
      loaded_before: loaded_before,
      loaded_after: loaded_after,
      handlers: length(handlers),
      out: out
    })
  end

  # Fetch entries for `docs` in chunks of `chunk`, sleeping `pace_ms` between
  # chunks. Each element is {entry, transfer_size}.
  defp fetch_chunked(docs, chunk, pace_ms, erpc) do
    docs
    |> Enum.chunk_every(chunk)
    |> Enum.with_index()
    |> Enum.flat_map(fn {batch, i} ->
      if i > 0 and pace_ms > 0, do: Process.sleep(pace_ms)
      Enum.map(batch, &fetch_one(&1, erpc))
    end)
  end

  # The ONLY task-specific read logic: erpc readers injected into the tested
  # build_entry/3. latest is captured for the transfer metric, then discarded.
  defp fetch_one(doc, erpc) do
    latest = erpc.(CommitStore, :latest_commit, [doc])
    read_heads = fn d -> erpc.(CommitStore, :accepted_heads_indexed, [d]) end

    size =
      case latest do
        {:ok, c} -> :erlang.external_size(c)
        _ -> 0
      end

    {AcceptedHeadsCoverage.build_entry(fn _ -> latest end, read_heads, doc), size}
  end

  defp read_rss(pid) do
    "/proc/#{pid}/status"
    |> File.read!()
    |> String.split("\n")
    |> Enum.find_value(fn l ->
      case Regex.run(~r/^VmRSS:\s+(\d+)\s+kB/, l) do
        [_, kb] -> String.to_integer(kb)
        _ -> nil
      end
    end)
  end

  defp write_capture(out, all?, chunk, total, report, skew, still_missing, entries) do
    capture = %{
      scope: if(all?, do: :full, else: :canary),
      chunk: chunk,
      total_docs: total,
      verdict: report,
      skew_count: skew,
      first_pass_missing: length(report.missing),
      second_pass_missing: length(still_missing),
      entries:
        Enum.map(entries, fn {d, lid, h} ->
          %{doc: d, latest_id: lid, heads: Enum.sort(MapSet.to_list(h))}
        end)
    }

    File.write!(out, inspect(capture, limit: :infinity, printable_limit: :infinity))
  end

  defp print_report(m) do
    r = m.report
    per_doc = if m.scope_n > 0, do: m.elapsed_us / m.scope_n, else: 0.0

    extrap =
      if not m.all? and m.scope_n > 0 do
        wall_s = m.elapsed_us / 1_000 * m.total / m.scope_n / 1000
        mb = m.transfer_total / m.scope_n * m.total / 1_048_576

        "\n  extrapolation to #{m.total}.... ~#{Float.round(wall_s, 1)} s wall, ~#{Float.round(mb, 1)} MB transfer (LINEAR, mean-based — the MAX tail is NOT captured)"
      else
        ""
      end

    IO.puts("""

    ════════ COVERAGE #{if m.all?, do: "FULL RUN", else: "CANARY"} (#{m.scope_n} / #{m.total} docs) ════════
      wall time (fetch)........ #{Float.round(m.elapsed_us / 1_000, 1)} ms  (#{Float.round(per_doc, 1)} µs/doc)
      bytes transferred........ #{m.transfer_total} B total; largest single commit #{m.transfer_max} B  ⚠️ LOWER BOUND (a #{m.scope_n}-sample understates a maximum)
      serve RSS before/after... #{m.rss_before} kB → #{m.rss_after} kB  (Δ #{m.rss_after - m.rss_before} kB)
      verdict.................. examined=#{r.examined} covered=#{r.covered} missing=#{length(r.missing)} vacuous=#{r.vacuous} green=#{r.green}
      skew (re-read)........... pass1 missing=#{m.first_missing}, pass2 still-missing=#{m.still_missing}, SKEW=#{m.skew}
      non-perturbation......... serve :code.all_loaded #{m.loaded_before} → #{m.loaded_after} (#{if m.loaded_before == m.loaded_after, do: "UNCHANGED ✓", else: "CHANGED ✗ — a module loaded"})
      telemetry handlers....... #{m.handlers} on latest_read
      capture written.......... #{m.out}#{extrap}
    ═══════════════════════════════════════════════════════════════════
    #{if m.all?, do: "FULL RUN complete. green=#{r.green} authorizes §4 iff examined>0, missing==[], and skew is understood.", else: "HALTED after canary by design. Review the metrics, then re-run with --all (optionally --pace-ms)."}
    """)
  end
end

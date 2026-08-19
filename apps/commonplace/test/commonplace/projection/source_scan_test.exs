defmodule Commonplace.Projection.SourceScanTest do
  @moduledoc """
  CX-6scm's two source-scan guards — the third and fourth applications of
  the CX-jfok pattern.

  A chokepoint that is merely *documented* as the only way in is a
  chokepoint until the next person adds a second door. The six-sites
  lesson says the guard has to be mechanical, and the CX-jfok pattern
  says the guard only counts once it has been proven red by injecting a
  violation.

  Both scans below carry an explicit ALLOWLIST rather than a pattern
  exemption. An allowlist entry is a named decision a reviewer can read;
  a clever regex that happens not to match is an exemption nobody voted
  for.

  ## Red-proofs

  Recorded in the CX-6scm build report: each scan was proven red by
  adding one violating call site, the failure output captured, and the
  injection removed.
  """
  use ExUnit.Case, async: true

  # Umbrella root. The denominator test below exists because the first
  # draft of this line was off by one directory and every scan matched
  # ZERO files — both guards would have passed forever while checking
  # nothing.
  @app_root Path.expand("../../../../..", __DIR__)

  defp source_files do
    Path.wildcard(Path.join(@app_root, "apps/*/lib/**/*.ex"))
  end

  # Comment lines are excluded: a moduledoc that MENTIONS
  # `reconstruct_doc_at/3` is not a caller, and a guard that cannot tell
  # the difference gets muted by the first person it annoys.
  defp hits(regex) do
    for path <- source_files(),
        {line, n} <- Enum.with_index(File.read!(path) |> String.split("\n"), 1),
        trimmed = String.trim(line),
        not String.starts_with?(trimmed, "#"),
        Regex.match?(regex, line),
        do: {Path.relative_to(path, @app_root), n, trimmed}
  end

  # ── Guard 1: the caller-side pin-read chokepoint ───────────────────

  # Reconstructing a doc AT A COMMIT is the pin read. Every one of them
  # must go through `Commonplace.Projection`, or it is a projection that
  # bypasses the verdict — the read-side analog of a write that bypasses
  # the gate, and it gets the same treatment.
  #
  # Each entry is {file, why}. "why" is the standard: an exemption has to
  # justify itself in words, in the file a reviewer already has open.
  @pin_read_allowlist %{
    "apps/commonplace/lib/commonplace/tree/doc_builder.ex" =>
      "defines the primitive; Projection's tier (iii) replay and chain_to/3 are its callers",
    "apps/commonplace/lib/commonplace/projection.ex" => "IS the chokepoint",
    "apps/commonplace/lib/commonplace/document/server.ex" =>
      "rebase baseline at the doc's OWN parent_commit, inside the write path — " <>
        "it reconstructs the state it is about to extend, not a historical pin a " <>
        "consumer asked to see. Rerouting it would put a verdict-bearing read on " <>
        "every write tick. Named, not silently skipped (CX-6scm follow-up).",
    "apps/commonplace/lib/commonplace/view_action_dispatch.ex" =>
      "PR-ancestor read for merge-base computation; same write-path argument as " <>
        "document/server.ex. Named as a follow-up, not an unbounded exemption.",

    # ── The enumerated reroute backlog ──────────────────────────────
    #
    # These are consumer-facing pin reads that SHOULD carry a verdict and
    # do not yet. They are listed individually, with counts, rather than
    # covered by a wildcard: the point of this guard is that the backlog
    # is a finite reviewable list instead of invisible sprawl. Rerouting
    # each is a behaviour change (a conflicted pin becomes a refusal, per
    # the §7.6 ruling), so each needs its own consumer decision about
    # what to do with `{:unknown, _}` — which is exactly the review the
    # design says is required and which cannot be done in bulk.
    "apps/commonplace/lib/commonplace/black.ex" =>
      "1 site (pinned dir read). Reroute pending: Black's consumer contract " <>
        "for {:unknown,_} is unwritten.",
    "apps/commonplace/lib/commonplace/git_bridge/inbound.ex" =>
      "4 sites (anchor-replica reads under a fixed hand + clock_floor). Reroute " <>
        "pending: these pass Doc.new opts through and feed a three-way merge; " <>
        "a refusal mid-merge needs its own design.",
    "apps/commonplace/lib/commonplace/tree/cherrypick.ex" =>
      "2 sites (source + parent state for a cherry-pick). Write path.",
    "apps/commonplace/lib/commonplace/tree/fork.ex" =>
      "2 sites (fork-at-commit source state). Write path.",
    "apps/commonplace/lib/commonplace/tree/merge.ex" =>
      "1 site (merge_leaf baseline). Write path."
  }

  test "every reconstruct-at-commit caller routes through Commonplace.Projection" do
    offenders =
      ~r/DocBuilder\.reconstruct_doc_at\(/
      |> hits()
      |> Enum.reject(fn {file, _, _} -> Map.has_key?(@pin_read_allowlist, file) end)

    assert offenders == [],
           """
           reconstruct-at-commit called outside Commonplace.Projection:

           #{Enum.map_join(offenders, "\n", fn {f, n, l} -> "  #{f}:#{n}  #{l}" end)}

           Pin reads must go through `Commonplace.Projection.project_at/3` so the
           caller receives a verdict. If this site genuinely cannot (a write-path
           baseline read, say), add it to @pin_read_allowlist WITH ITS REASON.
           """
  end

  test "the pin-read allowlist has no dead entries" do
    live =
      ~r/DocBuilder\.reconstruct_doc_at\(|def reconstruct_doc_at\(|defmodule Commonplace\.Projection do/
      |> hits()
      |> MapSet.new(fn {file, _, _} -> file end)

    dead = Enum.reject(Map.keys(@pin_read_allowlist), &MapSet.member?(live, &1))

    assert dead == [],
           "allowlist entries no longer needed (delete them, do not let them rot): #{inspect(dead)}"
  end

  # ── Guard 2: the mint-side hash-less-origin guard ──────────────────

  # `post_state_hash` must be minted at the BUILD pipeline. Every site
  # that mints a `Commit` directly, bypassing `CommitBuilder.build/6`,
  # either threads its own post-state or is named here as
  # legacy-compatible — and a legacy-compatible site produces commits
  # that project at the CORROBORATION ceiling forever, which is a real
  # cost, not a formality.
  @mint_allowlist %{
    "apps/commonplace/lib/commonplace/store/commit_builder.ex" =>
      "THE build pipeline — threads `post_state:` into Commit.new/6",
    "apps/commonplace/lib/commonplace/store/commit_store.ex" =>
      "legacy-compatible: write_snapshot_cas mints inside the serialized section " <>
        "from bytes it did not author; no in-memory post-state doc to encode",
    "apps/commonplace/lib/commonplace/store/translator.ex" =>
      "legacy-compatible: late-edit translation re-addresses an EXISTING edit " <>
        "against a new snapshot; the post-state belongs to the original writer " <>
        "and minting one here would manufacture a witness (no retroactive WITNESSED)",
    "apps/commonplace/lib/commonplace/store/cross_epoch_merge.ex" =>
      "legacy-compatible: mints a merge commit from reconciled bytes; threading " <>
        "the post-state needs the merged doc canonically encoded at the site — " <>
        "the named cost centre, deferred",
    "apps/commonplace/lib/commonplace/store/merge_snapshotter.ex" =>
      "legacy-compatible: same as cross_epoch_merge — deferred cost centre",
    "apps/commonplace/lib/commonplace/store/commit.ex" =>
      "defines Commit.new/6 (moduledoc examples only)"
  }

  test "a hash-less commit can only originate from a named legacy-compatible site" do
    offenders =
      ~r/Commit\.new\(/
      |> hits()
      |> Enum.reject(fn {file, _, _} -> Map.has_key?(@mint_allowlist, file) end)

    assert offenders == [],
           """
           Commit.new/6 called from a site that is neither the build pipeline nor a
           named legacy-compatible mint site:

           #{Enum.map_join(offenders, "\n", fn {f, n, l} -> "  #{f}:#{n}  #{l}" end)}

           Either route the write through `CommitBuilder.build/6` with `post_state:`,
           or add the site to @mint_allowlist WITH ITS REASON. Commits minted without
           a post-state hash can never be WITNESSED — that is a permanent property of
           every row they write, so the exemption is a real decision.
           """
  end

  test "the mint allowlist has no dead entries" do
    live = ~r/Commit\.new\(/ |> hits() |> MapSet.new(fn {file, _, _} -> file end)
    dead = Enum.reject(Map.keys(@mint_allowlist), &MapSet.member?(live, &1))

    assert dead == [],
           "allowlist entries no longer needed (delete them, do not let them rot): #{inspect(dead)}"
  end

  test "the scans actually see the codebase (denominator, not a false zero)" do
    # A scan that silently matched nothing would pass both guards above
    # forever. Pin the denominators so a broken glob or a renamed call
    # fails loudly instead of quietly certifying an empty set.
    # Observed at CX-6scm time: 407 lib files, 8 `Commit.new(` lines,
    # 13 `reconstruct_doc_at(` call sites. The floors sit below those so
    # ordinary refactoring does not trip them, but an empty or
    # near-empty scan does.
    assert length(source_files()) > 300
    assert length(hits(~r/Commit\.new\(/)) >= 6
    assert length(hits(~r/DocBuilder\.reconstruct_doc_at\(/)) >= 8
  end
end

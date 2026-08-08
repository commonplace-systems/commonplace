defmodule Commonplace.Tree.ReconstructDocSourceScanTest do
  @moduledoc """
  CX-68m6's reader-discipline application of the CX-jfok allowlist-scan
  pattern. Every direct HEAD reconstruction call is a named decision because
  `DocBuilder.reconstruct_doc/3` may mint a lazy snapshot commit by default.

  Counts are pinned per file as well as filenames: adding a call to a file
  already reviewed must still fail until that individual use is classified.
  """
  use ExUnit.Case, async: true

  @app_root Path.expand("../../../../..", __DIR__)

  # Each entry is %{calls:, class:, reason:}. Ambiguous is a classification,
  # not an exemption: the behavior stays unchanged pending a caller-specific
  # posture decision, as required by CX-68m6's no-default-flip fence.
  @caller_allowlist %{
    "apps/commonplace/lib/commonplace/audit/lww_loss.ex" => %{
      calls: 1,
      class: :read_only_required,
      reason: "store audit; passes read_only: true so measuring loss cannot perturb the corpus"
    },
    "apps/commonplace/lib/commonplace/bd/issue.ex" => %{
      calls: 1,
      class: :minting_intended,
      reason:
        "interactive issue-description HEAD read; ordinary production reads retain lazy compaction"
    },
    "apps/commonplace/lib/commonplace/bd/schemas.ex" => %{
      calls: 5,
      class: :ambiguous,
      reason:
        "mixed schema loaders and writer baselines; load_issue threads caller opts so bd invariants are read-only, while unrelated established callers stay unchanged"
    },
    "apps/commonplace/lib/commonplace/black.ex" => %{
      calls: 2,
      class: :minting_intended,
      reason: "production pattern document HEAD reads"
    },
    "apps/commonplace/lib/commonplace/git_bridge/exporter.ex" => %{
      calls: 1,
      class: :minting_intended,
      reason: "production export reads current content and may compact deep HEAD chains"
    },
    "apps/commonplace/lib/commonplace/git_bridge/inbound.ex" => %{
      calls: 2,
      class: :minting_intended,
      reason: "inbound merge/write baselines over current document state"
    },
    "apps/commonplace/lib/commonplace/merge_command/handler.ex" => %{
      calls: 1,
      class: :minting_intended,
      reason: "merge command write baseline; not a measurement or audit"
    },
    "apps/commonplace/lib/commonplace/mud/bot.ex" => %{
      calls: 1,
      class: :minting_intended,
      reason: "production MUD bot content read"
    },
    "apps/commonplace/lib/commonplace/mud/ghost_reaper.ex" => %{
      calls: 1,
      class: :ambiguous,
      reason:
        "maintenance read feeding deletion decisions; lazy compaction posture is not decided here"
    },
    "apps/commonplace/lib/commonplace/mud/schemas.ex" => %{
      calls: 3,
      class: :minting_intended,
      reason: "runtime schema loads plus stable-hand write baselines"
    },
    "apps/commonplace/lib/commonplace/mud/session_view.ex" => %{
      calls: 2,
      class: :minting_intended,
      reason: "production session transcript HEAD reads"
    },
    "apps/commonplace/lib/commonplace/mud/verb_source.ex" => %{
      calls: 2,
      class: :minting_intended,
      reason: "runtime verb-source read and its stable-hand write baseline"
    },
    "apps/commonplace/lib/commonplace/mud/world.ex" => %{
      calls: 3,
      class: :minting_intended,
      reason: "production world/schema HEAD reads"
    },
    "apps/commonplace/lib/commonplace/outline.ex" => %{
      calls: 3,
      class: :minting_intended,
      reason: "production outline reads and mutation baselines"
    },
    "apps/commonplace/lib/commonplace/presence/compactor.ex" => %{
      calls: 2,
      class: :minting_intended,
      reason: "explicit compaction workflow reading current presence state"
    },
    "apps/commonplace/lib/commonplace/presence/identity.ex" => %{
      calls: 1,
      class: :minting_intended,
      reason: "production identity HEAD read"
    },
    "apps/commonplace/lib/commonplace/projection.ex" => %{
      calls: 1,
      class: :read_only_required,
      reason:
        "verification authority; passes read_only: true to avoid moving the HEAD it verifies"
    },
    "apps/commonplace/lib/commonplace/store/gc.ex" => %{
      calls: 1,
      class: :ambiguous,
      reason:
        "GC reconstruction feeds a maintenance write; changing its compaction posture needs a separate decision"
    },
    "apps/commonplace/lib/commonplace/store/snapshotter.ex" => %{
      calls: 1,
      class: :ambiguous,
      reason:
        "snapshot construction can request a coalesced lazy rerun; removing that established interaction is deferred"
    },
    "apps/commonplace/lib/commonplace/sync/dir_agent.ex" => %{
      calls: 2,
      class: :minting_intended,
      reason: "live sync reads current schema state"
    },
    "apps/commonplace/lib/commonplace/sync/schema_coordinator.ex" => %{
      calls: 1,
      class: :minting_intended,
      reason: "live coordinator reads current schema state"
    },
    "apps/commonplace/lib/commonplace/tree/fork.ex" => %{
      calls: 1,
      class: :minting_intended,
      reason: "fork write-path baseline read"
    },
    "apps/commonplace/lib/commonplace/tree/merge.ex" => %{
      calls: 1,
      class: :minting_intended,
      reason: "merge write-path baseline read"
    },
    "apps/commonplace/lib/commonplace/trust.ex" => %{
      calls: 3,
      class: :ambiguous,
      reason:
        "trust validation reads also serve live request paths; posture change requires a trust-path decision"
    },
    "apps/commonplace/lib/commonplace/trust/read_meta.ex" => %{
      calls: 1,
      class: :ambiguous,
      reason:
        "trust metadata read is verification-adjacent but also a production read; left unchanged pending review"
    },
    "apps/commonplace/lib/commonplace/view_action_dispatch.ex" => %{
      calls: 2,
      class: :minting_intended,
      reason: "production view-action reads, including a stable-hand mutation baseline"
    },
    "apps/commonplace_cli/lib/commonplace/cli/cat.ex" => %{
      calls: 1,
      class: :minting_intended,
      reason: "ordinary user-facing HEAD read; lazy compaction is the deliberate default"
    },
    "apps/commonplace_web/lib/commonplace_web_web/live/mud_live.ex" => %{
      calls: 1,
      class: :minting_intended,
      reason: "interactive production LiveView HEAD read"
    },
    "apps/commonplace_web/lib/commonplace_web_web/live/tree_live.ex" => %{
      calls: 1,
      class: :minting_intended,
      reason: "interactive production LiveView HEAD read"
    },
    "apps/commonplace_web/lib/commonplace_web_web/live/wiki_live.ex" => %{
      calls: 1,
      class: :minting_intended,
      reason: "interactive production LiveView HEAD read"
    }
  }

  defp source_files do
    Path.wildcard(Path.join(@app_root, "apps/*/lib/**/*.ex"))
  end

  defp hits do
    regex = ~r/(?:DocBuilder|Commonplace\.Tree\.DocBuilder)\.reconstruct_doc\(/

    for path <- source_files(),
        {line, n} <- Enum.with_index(File.read!(path) |> String.split("\n"), 1),
        trimmed = String.trim(line),
        not String.starts_with?(trimmed, "#"),
        Regex.match?(regex, line),
        do: {Path.relative_to(path, @app_root), n, trimmed}
  end

  test "every reconstruct_doc caller has a counted reader-discipline classification" do
    actual_counts = hits() |> Enum.frequencies_by(fn {file, _, _} -> file end)

    expected_counts =
      Map.new(@caller_allowlist, fn {file, %{calls: calls}} -> {file, calls} end)

    assert actual_counts == expected_counts,
           """
           reconstruct_doc/3 caller inventory changed.

           Actual calls by file: #{inspect(actual_counts, pretty: true)}
           Classified calls:    #{inspect(expected_counts, pretty: true)}

           Every direct HEAD reconstruction is a possible write. Classify each new
           call as :minting_intended, :read_only_required, or :ambiguous WITH A
           REASON; read-only-required callers must pass `read_only: true`. Update a
           file's exact call count when (and only when) the new site is reviewed.
           """
  end

  test "every classification is explicit and reasoned" do
    allowed = [:minting_intended, :read_only_required, :ambiguous]

    malformed =
      Enum.reject(@caller_allowlist, fn {_file, entry} ->
        entry.class in allowed and is_binary(entry.reason) and String.trim(entry.reason) != "" and
          entry.calls > 0
      end)

    assert malformed == [], "malformed reconstruct_doc classifications: #{inspect(malformed)}"
  end

  test "the caller scan actually sees the codebase" do
    assert length(source_files()) > 300
    assert length(hits()) >= 40
    assert map_size(@caller_allowlist) >= 25
  end
end

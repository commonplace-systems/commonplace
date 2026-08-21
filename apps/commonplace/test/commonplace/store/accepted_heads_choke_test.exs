defmodule Commonplace.Store.AcceptedHeadsChokeTest do
  @moduledoc """
  BUILD-1 increment 2: the accepted-head-set row is CONSTRUCTED in exactly
  one place. Mirrors the `{:latest, _}` source scan in
  `invariant_choke_test.exs`: a rule enforced by a line inside a function
  is enforced until someone edits that function; a rule enforced by a scan
  that goes red outlives the edit.

  The head set is a single row `{{:accepted_heads, doc_uuid}, MapSet}`.
  Its write shape is built only in `accepted_heads_row/4`; the two persist
  sites (`put_latest/5`, `put_bare_commit_with_index/2`) splice that row as
  a VARIABLE into their put_multi, so the literal never appears there. A
  head-set write that skips the seam would compute the frontier without
  the domination delta — the exact drift this scan forbids.
  """
  use ExUnit.Case, async: true

  describe "source scan: only accepted_heads_row builds the head-set row" do
    test "no {:accepted_heads, _} write shape outside CommitStore.accepted_heads_row/4" do
      offenders =
        Path.wildcard(Path.join(lib_root(), "**/*.ex"), match_dot: false)
        |> Enum.flat_map(&head_set_writes/1)
        # accepted_heads_row = the incremental delta seam; accepted_heads_backfill_row
        # = the §3 one-time full-set write. Both construct the head-set row; both
        # are sanctioned. Nothing else may.
        |> Enum.reject(fn %{function: function} ->
          function in ["accepted_heads_row", "accepted_heads_backfill_row"]
        end)

      assert offenders == [],
             """
             An `{:accepted_heads, _}` head-SET write was found outside
             `Commonplace.Store.CommitStore.accepted_heads_row/4`. The
             frontier must be built only in that seam so the domination
             delta ((old - dominated) ∪ new) is applied uniformly; a site
             that constructs the row itself can write a frontier that
             disagrees with the scan oracle.

             Offending sites:
             #{Enum.map_join(offenders, "\n", fn o -> "  #{o.file}:#{o.line} (in #{o.function}/?)\n    #{String.trim(o.text)}" end)}
             """
    end
  end

  # Anchored on __DIR__, not cwd — a scan that silently globs zero files is
  # the emptiest kind of false green (same rationale as invariant_choke).
  defp lib_root do
    Path.expand(Path.join(__DIR__, "../../../lib"))
  end

  # Delegates to the shared AST scanner (Commonplace.Test.RowKeyWriteScanner) —
  # the accepted-head-set row is the `{:accepted_heads, _}` twin of the
  # `{:latest, _}` head pointer, and shared the same line-text fragility before
  # this. Both-directions controls live in the scanner's own test.
  defp head_set_writes(path) do
    Commonplace.Test.RowKeyWriteScanner.writes_in_file(path, :accepted_heads)
  end

  describe "source scan: the scanner itself can fail" do
    test "a synthetic offender is reported with its function name" do
      tmp = Path.join(System.tmp_dir!(), "cp_ahs_scan_#{:rand.uniform(1_000_000_000)}.ex")

      File.write!(tmp, """
      defmodule Fake do
        defp sneaky_headset(db, uuid, set) do
          CubDB.put(db, {:accepted_heads, uuid}, set)
        end
      end
      """)

      on_exit(fn -> File.rm_rf!(tmp) end)

      assert [%{function: "sneaky_headset", line: 3}] = head_set_writes(tmp)
    end
  end
end

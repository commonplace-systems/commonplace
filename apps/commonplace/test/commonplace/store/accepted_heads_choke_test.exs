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
        |> Enum.reject(fn %{function: function} -> function == "accepted_heads_row" end)

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

  defp head_set_writes(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({nil, []}, fn {line, lineno}, {current_function, hits} ->
      current_function =
        case Regex.run(~r/^\s{0,4}defp?\s+([a-z_][a-zA-Z0-9_?!]*)/, line) do
          [_, fun] -> fun
          nil -> current_function
        end

      if head_set_write?(line) do
        {current_function,
         [%{file: path, line: lineno, function: current_function, text: line} | hits]}
      else
        {current_function, hits}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp head_set_write?(line) do
    String.starts_with?(String.trim_leading(line), "{{:accepted_heads,") or
      (String.contains?(line, "{:accepted_heads,") and String.contains?(line, "CubDB.put"))
  end

  # A control that cannot go red is not a control.
  describe "source scan: the scanner itself can fail" do
    test "recognises the write shape and neither read shape" do
      assert head_set_write?(~s|    {{:accepted_heads, doc_uuid}, new}|)
      assert head_set_write?(~s|  CubDB.put(db, {:accepted_heads, u}, set)|)

      refute head_set_write?(
               "    old = CubDB.get(db, {:accepted_heads, doc_uuid}) || MapSet.new()"
             )

      refute head_set_write?(
               "      _latest -> {:ok, CubDB.get(db, {:accepted_heads, doc_uuid}) || MapSet.new()}"
             )
    end
  end
end

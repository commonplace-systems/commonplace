defmodule Commonplace.Test.RowKeyWriteScannerTest do
  @moduledoc """
  Both-directions controls for the shared row-key write scanner (the class
  hardening for the source-scan choke invariants). A scanner that cannot be
  seen to catch a forbidden write, and to leave every read alone, is not known
  to work — especially the read whose `{{key,_},_}` pattern sits on its own
  line, which is the exact shape the line-text matchers this replaced got wrong.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Test.RowKeyWriteScanner, as: Scanner

  describe "writes are caught" do
    test "a direct CubDB.put of the key" do
      assert [%{shape: :cubdb_put, function: "f"}] =
               Scanner.writes_in_source(
                 "def f(db, u, id), do: CubDB.put(db, {:latest, u}, id)",
                 :latest
               )
    end

    test "an inline put_multi row" do
      assert [%{shape: :put_multi_row}] =
               Scanner.writes_in_source(
                 "def f(db, u, id), do: CubDB.put_multi(db, [{{:latest, u}, id}])",
                 :latest
               )
    end

    test "the real put_latest shape — a row spliced into the list via ++" do
      assert [%{shape: :put_multi_row, function: "put_latest"}] =
               Scanner.writes_in_source(
                 "def put_latest(db, rows, u, id), do: CubDB.put_multi(db, rows ++ [{{:latest, u}, id}])",
                 :latest
               )
    end
  end

  describe "reads are not caught" do
    test "a CubDB.get of the key" do
      assert [] =
               Scanner.writes_in_source("def f(db, u), do: CubDB.get(db, {:latest, u})", :latest)
    end

    test "min_key/max_key range bounds (atom-first, not the nested row shape)" do
      assert [] =
               Scanner.writes_in_source(
                 ~s|def f(db), do: CubDB.select(db, min_key: {:latest, ""}, max_key: {:latest, "z"})|,
                 :latest
               )
    end

    test "an inline fn destructure of the row" do
      assert [] =
               Scanner.writes_in_source(
                 "def f(rows), do: Enum.map(rows, fn {{:latest, u}, _c} -> u end)",
                 :latest
               )
    end

    test "⭐ the World-B shape: a reduce-clause pattern on its OWN line" do
      # The line-text matcher keyed on "starts with {{:latest," and false-flagged
      # this read as a write. The AST classifier sees a PATTERN. This is the
      # regression this whole class-hardening exists to prevent.
      assert [] =
               Scanner.writes_in_source(
                 """
                 def f(rows) do
                   Enum.reduce(rows, %{}, fn
                     {{:latest, doc_uuid}, _commit_id}, acc ->
                       Map.put(acc, doc_uuid, true)
                   end)
                 end
                 """,
                 :latest
               )
    end
  end

  describe "the key is honoured, not any nested tuple" do
    test "a different key's write is not the scanned key's write" do
      assert [] =
               Scanner.writes_in_source(
                 "def f(db, t, id), do: CubDB.put(db, {:latest_merge_head, t}, id)",
                 :latest
               )
    end

    test "the same source scanned for its OWN key IS caught (the twin)" do
      src = "def f(db, u, s), do: CubDB.put_multi(db, [{{:accepted_heads, u}, s}])"
      assert [] = Scanner.writes_in_source(src, :latest)
      assert [%{shape: :put_multi_row}] = Scanner.writes_in_source(src, :accepted_heads)
    end
  end

  describe "a corpus that cannot be parsed is surfaced, not swallowed" do
    test "a parse error becomes an offender, not a false green" do
      tmp = Path.join(System.tmp_dir!(), "cp_scanner_parse_#{:rand.uniform(1_000_000_000)}.ex")
      File.write!(tmp, "defmodule Broken do\n  def f(, do: :oops\nend\n")
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert [%{shape: :parse_error, file: ^tmp}] = Scanner.writes_in_file(tmp, :latest)
    end
  end
end

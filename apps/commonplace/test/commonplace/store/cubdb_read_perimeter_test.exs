defmodule Commonplace.Store.CubDBReadPerimeterTest do
  @moduledoc """
  BUILD-2a's load-bearing half: the source guard
  (`scripts/check_commonplace_cubdb_reads.exs`) that fails CI when product
  code reaches CubDB directly outside the storage adapter.

  A gate never seen fail is not known to work, and one that cannot go green
  on correct state is its mirror — so this proves BOTH directions: green on
  the real tree (and non-blind), red on an injected violation of each kind.
  """
  use ExUnit.Case, async: true

  @project_root Path.expand("../../../../..", __DIR__)
  @checker Path.join(@project_root, "scripts/check_commonplace_cubdb_reads.exs")

  defp run(root), do: System.cmd("elixir", [@checker, root], stderr_to_stdout: true)

  # Build a MINIMAL temp root with an explicit set of {relative_path, source}
  # files under it. Faster and more isolated than copying the whole app tree,
  # and it exercises the SAME `apps/*/lib/**/*.ex` glob — including its
  # cross-app reach, which is why a violation below is placed in `_web`.
  defp temp_root(files) do
    root =
      Path.join(
        System.tmp_dir!(),
        "cubdb-read-perimeter-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)

    Enum.each(files, fn {relative, source} ->
      path = Path.join(root, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, source)
    end)

    root
  end

  # An allowlisted adapter file that DOES touch CubDB — present in every temp
  # root so the scanner has a legitimate access to classify as allowed (the
  # non-blind control), and so a green temp root is a real green, not an empty
  # one.
  defp adapter_file do
    {"apps/commonplace/lib/commonplace/store/legit_adapter.ex",
     """
     defmodule Commonplace.Store.LegitAdapter do
       def read(db), do: CubDB.get(db, {:commit, "x"})
     end
     """}
  end

  test "green: the real tree passes, and the scanner is non-blind" do
    {output, status} = run(@project_root)

    assert status == 0, output
    assert output =~ "commonplace cubdb read-perimeter check passed"

    # Positive control: the scanner actually MATCHED CubDB access and allowed
    # it because it was in-adapter. A green with zero allowed sites would be a
    # blind scanner, not a clean tree. Assert > 0 (the property), never an
    # exact count (which would be a count-to-bump).
    [_, count] = Regex.run(~r/allowed adapter access sites: (\d+)/, output)
    assert String.to_integer(count) > 0, output
  end

  test "red: raw CubDB access in a product module outside the adapter trips CI" do
    root =
      temp_root([
        adapter_file(),
        {"apps/commonplace/lib/commonplace/projection/bad_cubdb.ex",
         """
         defmodule Commonplace.Projection.BadCubDB do
           def read(db), do: CubDB.select(db, min_key: {:commit, ""})
         end
         """}
      ])

    {output, status} = run(root)

    assert status == 1, output
    assert output =~ "commonplace cubdb read-perimeter check failed"
    assert output =~ "projection/bad_cubdb.ex"
    assert output =~ "unexpected raw CubDB access"
  end

  test "red: the CommitStore.db_handle escape hatch trips CI — and does so in a DIFFERENT app" do
    # Placed in commonplace_web/lib, NOT commonplace/lib: the write-perimeter's
    # 2026-08-09 lesson is that a guard scoped to one app lets an identical
    # violation pass in another. A control that can only fire where the guard
    # already looks says nothing about its boundary. So this violation lives
    # across the app boundary, and catching it proves the `apps/*/lib` reach.
    root =
      temp_root([
        adapter_file(),
        {"apps/commonplace_web/lib/bad_handle.ex",
         """
         defmodule CommonplaceWeb.BadHandle do
           alias Commonplace.Store.CommitStore
           def read(store), do: CommitStore.db_handle(store)
         end
         """}
      ])

    {output, status} = run(root)

    assert status == 1, output
    assert output =~ "commonplace_web/lib/bad_handle.ex"
    assert output =~ "escape hatch"
  end

  test "a CubDB mention in a comment or docstring is not a violation (AST, not grep)" do
    # The green-making property: prose that names CubDB parses to string/comment
    # nodes, not call nodes, so it must NOT trip. A grep-based guard would flag
    # all three lines below. If this ever goes red, the guard regressed from AST
    # matching to text matching.
    root =
      temp_root([
        adapter_file(),
        {"apps/commonplace/lib/commonplace/projection/prose.ex",
         """
         defmodule Commonplace.Projection.Prose do
           @moduledoc "Historically read via CubDB.select; now routes through CommitReader."
           # CubDB.get and CommitStore.db_handle would both be wrong here.
           def read(_x), do: :ok
         end
         """}
      ])

    {output, status} = run(root)

    assert status == 0, output
    assert output =~ "commonplace cubdb read-perimeter check passed"
  end
end

defmodule Commonplace.Bd.SuppliedIdCreationScanTest do
  @moduledoc """
  CX-6cz3 BUILD CONDITION 3 (tix-authority migration design §7, rulings
  @6418506): "`create_with_fixed_id` gets a zero-non-dispatch-callers
  guard after the verb lands (source-scan test — the library stays
  enforcement-free by design, so the guard is that no caller outside
  the dispatch path exists, checked red-by-injection)."

  `Commonplace.Bd.*` does no enforcement of its own, so there is no
  library-side check to lean on: the ONLY thing standing between a
  supplied-id ticket creation and the `Commonplace.Bd.WriteGuard`
  chokepoint is that every call site chooses to run the gate. That is
  a property of the SOURCE, so it is checked against the source.

  Two assertions:

    1. the superseded name `create_with_fixed_id` (the raw-store
       supplied-id write in `Bd.Importer`, and its copy in
       `Bd.Migrate`) is GONE from `lib/` — there is one supplied-id
       creation primitive now, `Commonplace.Bd.Issue.create_with_id/5`.
    2. every file that CALLS that primitive is on the allowlist AND
       names `check_create` — i.e. it is a file that runs the creation
       gate. A new ungated caller anywhere in either app's `lib/` turns
       this test red.

  Proven red by injection (CX-6cz3 build report): adding a
  `Issue.create_with_id(...)` call to
  `apps/commonplace/lib/commonplace/bd/importer.ex` — a file with no
  `check_create` — fails assertion 2 with importer.ex named.
  """
  use ExUnit.Case, async: true

  # Matched as CALL/DEF shapes (`name(`), not as bare text — the
  # moduledocs that explain the retirement necessarily name the old
  # function, and a scan that cannot tell prose from a call site is a
  # scan that goes red for the wrong reason.
  @legacy_call ~r/create_with_fixed_id\s*\(/
  @primitive_call ~r/create_with_id\s*\(/

  # The definition site (the library primitive itself) plus the call
  # sites that are allowed to exist. Every entry here must run
  # `WriteGuard.check_create/4` before writing — asserted below, not
  # assumed from membership in this list.
  @definition_site "apps/commonplace/lib/commonplace/bd/issue.ex"
  @gated_call_sites [
    "apps/commonplace/lib/commonplace/view_action_dispatch.ex",
    "apps/commonplace/lib/commonplace/bd/migrate.ex"
  ]

  defp umbrella_root do
    # test cwd is the umbrella root under `mix test`; walk up from
    # __DIR__ as a belt-and-braces fallback so the scan can never
    # silently scan nothing.
    candidate = File.cwd!()

    if File.dir?(Path.join(candidate, "apps/commonplace/lib")) do
      candidate
    else
      Path.expand("../../../../..", __DIR__)
    end
  end

  defp lib_files do
    root = umbrella_root()

    files =
      ["apps/commonplace/lib/**/*.ex", "apps/commonplace_mcp/lib/**/*.ex"]
      |> Enum.flat_map(fn glob -> Path.wildcard(Path.join(root, glob)) end)

    assert length(files) > 100,
           "the scan found only #{length(files)} lib files — it is scanning the wrong tree"

    Enum.map(files, fn abs -> {Path.relative_to(abs, root), File.read!(abs)} end)
  end

  test "the superseded raw-store supplied-id writer is gone from lib/" do
    offenders =
      lib_files()
      |> Enum.filter(fn {_path, src} -> Regex.match?(@legacy_call, src) end)
      |> Enum.map(fn {path, _} -> path end)

    assert offenders == [],
           "an ungated `create_with_fixed_id(...)` supplied-id write still exists in: #{inspect(offenders)}"
  end

  test "every caller of the supplied-id creation primitive runs the creation gate" do
    files = lib_files()

    callers =
      files
      |> Enum.filter(fn {path, src} ->
        path != @definition_site and Regex.match?(@primitive_call, src)
      end)
      |> Enum.map(fn {path, _} -> path end)
      |> Enum.sort()

    # Non-vacuity: the definition really is where we think it is, and
    # there really are callers to judge.
    assert Enum.any?(files, fn {path, src} ->
             path == @definition_site and String.contains?(src, "def create_with_id(")
           end),
           "the primitive is not defined at #{@definition_site} — this scan is checking nothing"

    assert callers != [], "no call sites found — this scan is checking nothing"

    unlisted = callers -- @gated_call_sites

    assert unlisted == [],
           "ungated (or unreviewed) supplied-id creation call sites: #{inspect(unlisted)} — " <>
             "every ticket write must flow through Commonplace.Bd.WriteGuard"

    ungated =
      files
      |> Enum.filter(fn {path, src} ->
        path in callers and not String.contains?(src, "check_create")
      end)
      |> Enum.map(fn {path, _} -> path end)

    assert ungated == [],
           "these files create supplied-id tickets without naming the creation gate: #{inspect(ungated)}"
  end
end

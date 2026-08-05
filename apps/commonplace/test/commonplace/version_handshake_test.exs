defmodule Commonplace.VersionHandshakeTest do
  use ExUnit.Case, async: true

  alias Commonplace.VersionHandshake

  describe "local_digest/0" do
    test "returns an entry for every probe module, with binaries for real modules" do
      digest = VersionHandshake.local_digest()

      for mod <- VersionHandshake.probe_modules() do
        assert Map.has_key?(digest, mod)
        assert is_binary(digest[mod]) or digest[mod] == :unavailable
      end

      # These probe modules exist in this app, so they must have loaded
      # to real md5 binaries, not :unavailable.
      for mod <- VersionHandshake.probe_modules() do
        assert is_binary(digest[mod]), "expected #{inspect(mod)} to have a real md5, got #{inspect(digest[mod])}"
      end
    end
  end

  describe "compare/1" do
    test "comparing a node with itself is never a skew" do
      assert match?(:ok, VersionHandshake.compare(Node.self())) or
               match?({:wide_ok, _}, VersionHandshake.compare(Node.self()))
    end
  end

  describe "resident_digest/1" do
    test "against Node.self() with apps() returns a consistent map" do
      digest = VersionHandshake.resident_digest(VersionHandshake.apps())

      assert %{apps: apps, loaded: loaded, not_loaded_count: not_loaded_count, missing_apps: missing_apps} =
               digest

      assert apps == VersionHandshake.apps()
      assert is_map(loaded)
      assert map_size(loaded) > 0
      assert is_integer(not_loaded_count) and not_loaded_count >= 0
      assert is_list(missing_apps)

      for {mod, md5} <- loaded do
        assert is_atom(mod)
        assert is_binary(md5)
      end
    end

    test "a bogus app lands in missing_apps and does not raise" do
      digest = VersionHandshake.resident_digest([:no_such_app_xyz])

      assert digest.missing_apps == [:no_such_app_xyz]
      assert digest.loaded == %{}
      assert digest.not_loaded_count == 0
    end

    test "does not force-load a module that was not already loaded" do
      apps = VersionHandshake.apps()

      candidate =
        Enum.find_value(apps, fn app ->
          case :application.get_key(app, :modules) do
            {:ok, mods} ->
              Enum.find(mods, fn mod -> :code.is_loaded(mod) == false end)

            :undefined ->
              nil
          end
        end)

      if candidate do
        assert :code.is_loaded(candidate) == false

        VersionHandshake.resident_digest(apps)

        assert :code.is_loaded(candidate) == false,
               "resident_digest/1 force-loaded #{inspect(candidate)}, which it must never do"
      else
        # Every module across apps() is already loaded in this test VM —
        # there's no unloaded module available to prove the negative
        # against, so skip rather than assert something vacuous.
        IO.puts(
          "SKIPPED: no unloaded module found across #{inspect(apps)} in this test VM; " <>
            "cannot prove resident_digest/1 avoids force-loading without one."
        )
      end
    end
  end

  describe "compare_wide/1" do
    test "self-comparison produces zero skew and compared > 0" do
      assert {:ok, report} = VersionHandshake.compare_wide(Node.self())
      assert report.skew == []
      assert report.compared > 0
      assert is_list(report.apps)
    end
  end

  describe "format_wide_skew/1" do
    test "states actual coverage when skew is empty" do
      report = %{
        compared: 96,
        skew: [],
        serve_not_loaded: 327,
        missing_apps: [],
        apps: [:commonplace, :commonplace_bots],
        not_in_escript: 0
      }

      message = VersionHandshake.format_wide_skew(report)

      assert message =~ "96"
      assert message =~ "327"
      assert message =~ "commonplace"
    end

    test "states actual coverage when skew is non-empty" do
      report = %{
        compared: 50,
        skew: [%{module: Commonplace.MUD.Verbs, local: <<1, 2, 3>>, remote: <<4, 5, 6>>}],
        serve_not_loaded: 12,
        missing_apps: [],
        apps: [:commonplace],
        not_in_escript: 0
      }

      message = VersionHandshake.format_wide_skew(report)

      assert message =~ "50"
      assert message =~ "12"
      assert message =~ "Commonplace.MUD.Verbs"
      assert message =~ "bin/rebuild-mcp"
    end
  end

  describe "compare_digests/2" do
    test "a module unavailable on both sides is not reported as a skew" do
      local = %{Commonplace.MUD.Verbs => :unavailable, Commonplace.MUD.World => <<1, 2, 3>>}
      remote = %{Commonplace.MUD.Verbs => :unavailable, Commonplace.MUD.World => <<1, 2, 3>>}

      assert VersionHandshake.compare_digests(local, remote) == :ok
    end

    test "a module available on one side only is reported as a skew" do
      local = %{Commonplace.MUD.Verbs => <<1, 2, 3>>, Commonplace.MUD.World => <<9, 9, 9>>}
      remote = %{Commonplace.MUD.Verbs => :unavailable, Commonplace.MUD.World => <<9, 9, 9>>}

      assert {:skew, [%{module: Commonplace.MUD.Verbs, local: <<1, 2, 3>>, remote: :unavailable}]} =
               VersionHandshake.compare_digests(local, remote)
    end

    test "mismatching binaries on both sides are reported as a skew" do
      local = %{Commonplace.MUD.Verbs => <<1, 2, 3>>}
      remote = %{Commonplace.MUD.Verbs => <<4, 5, 6>>}

      assert {:skew, [%{module: Commonplace.MUD.Verbs, local: <<1, 2, 3>>, remote: <<4, 5, 6>>}]} =
               VersionHandshake.compare_digests(local, remote)
    end
  end

  describe "format_skew/1" do
    test "names both mismatching modules and the remedy" do
      skew = [
        %{module: Commonplace.MUD.Verbs, local: <<1, 2, 3>>, remote: <<4, 5, 6>>},
        %{module: Commonplace.Tree.DocBuilder, local: <<7, 8, 9>>, remote: <<10, 11, 12>>}
      ]

      message = VersionHandshake.format_skew(skew)

      assert message =~ "Commonplace.MUD.Verbs"
      assert message =~ "Commonplace.Tree.DocBuilder"
      assert message =~ "bin/rebuild-mcp"
    end

    test "the narrow message ADMITS it is a sample, not a sweep (CX-vknn)" do
      message =
        VersionHandshake.format_skew([
          %{module: Commonplace.MUD.Verbs, local: <<1>>, remote: <<2>>}
        ])

      # The whole bug this bead names is narrow coverage stated in
      # complete language. If this wording ever regresses to implying
      # the probe set is the universe, that is the defect returning.
      assert message =~ ~r/sample|sampled|narrow/i,
             "the narrow fallback message must say it only sampled a few sentinel modules:\n#{message}"
    end
  end

  describe "format_coverage_line/1 (CX-vknn)" do
    # A PASSING check that prints nothing is the failure this bead is
    # about: silence gets read as "everything matches" when it really
    # means "the already-loaded subset matches". If this line ever
    # regresses to empty, that inference comes back.
    test "a clean result still states how much was actually checked" do
      line =
        VersionHandshake.format_coverage_line(%{
          compared: 97,
          serve_not_loaded: 326,
          apps: VersionHandshake.apps()
        })

      assert line =~ "97"
      assert line =~ "326"
      assert line =~ ~r/not checked/i
      refute line == ""
    end
  end

  describe "wide-path fallback (CX-vknn)" do
    # This branch is what decides whether an OLDER serve — one whose
    # `commonplace` predates `resident_digest/1` — produces a (sampled)
    # warning or silence. An unreachable node exercises the same
    # `{:badrpc, _}` return that an :undef produces, which is the
    # condition `compare/1` keys its fallback on.
    @unreachable :"cx_vknn_no_such_node@127.0.0.1"

    test "compare_wide/1 degrades to {:error, :no_wide_digest} instead of raising" do
      assert {:error, :no_wide_digest} = VersionHandshake.compare_wide(@unreachable)
    end

    test "compare/1 falls through to the narrow path rather than crashing" do
      # Both paths fail for an unreachable node — the point is that the
      # wide failure is not fatal and control reaches the narrow probe,
      # which reports its own honest error.
      assert {:error, _} = VersionHandshake.compare(@unreachable)
    end
  end
end

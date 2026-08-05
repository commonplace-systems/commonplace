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
      assert VersionHandshake.compare(Node.self()) == :ok
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
  end
end

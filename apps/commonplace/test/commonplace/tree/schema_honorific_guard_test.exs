defmodule Commonplace.Tree.SchemaHonorificGuardTest do
  @moduledoc """
  CX-edy: filenames ending in `.bot`, `.exe`, `.usr`, or `.who` are
  reserved for presence documents. Untrusted write paths must reject
  them to preserve the single-presence-location invariant (one
  presence file per actor, placed only by trusted paths —
  `Commonplace.Presence.*` and `Commonplace.Presence.Identity`).

  This module provides two public helpers:
    * `Schema.honorific_extension?/1` — pure predicate.
    * `Schema.forbid_honorific!/1` — raises ArgumentError on match.

  Trusted callers (presence/identity/fork) keep using
  `Schema.add_file/3` directly. Untrusted callers (CLI ln, CLI import,
  MCP write tool, future MCP move tool) call `forbid_honorific!/1` on
  user-provided names before invoking `add_file/3`.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Tree.Schema

  describe "honorific_extension?/1" do
    test "returns true for the four reserved extensions" do
      for name <- ["a.bot", "a.exe", "a.usr", "a.who", "deep.path.bot"] do
        assert Schema.honorific_extension?(name), "expected honorific: #{name}"
      end
    end

    test "returns false for unrelated extensions" do
      for name <- ["notes.txt", "image.png", "README", "data.json", "bot", "bot.txt"] do
        refute Schema.honorific_extension?(name), "unexpected honorific: #{name}"
      end
    end

    test "case-insensitive match — .BOT and .Bot are also rejected" do
      assert Schema.honorific_extension?("Alpha.BOT")
      assert Schema.honorific_extension?("Alpha.Bot")
      assert Schema.honorific_extension?("Alpha.Exe")
    end

    test "bare name with no dot returns false" do
      refute Schema.honorific_extension?("plain")
      refute Schema.honorific_extension?("")
    end
  end

  describe "forbid_honorific!/1" do
    test "returns :ok for safe names" do
      assert :ok = Schema.forbid_honorific!("notes.txt")
      assert :ok = Schema.forbid_honorific!("README")
    end

    test "raises ArgumentError for each reserved extension" do
      for ext <- [".bot", ".exe", ".usr", ".who"] do
        name = "myfile" <> ext

        assert_raise ArgumentError, fn ->
          Schema.forbid_honorific!(name)
        end
      end
    end

    test "error message names the rejected extension and the input" do
      try do
        Schema.forbid_honorific!("foo.bot")
        flunk("expected raise")
      rescue
        e in ArgumentError ->
          assert e.message =~ "foo.bot"
          assert e.message =~ ".bot"
      end
    end
  end
end

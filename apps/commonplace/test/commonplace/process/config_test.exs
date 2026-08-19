defmodule Commonplace.Process.ConfigTest do
  @moduledoc """
  Tests for parsing __processes.json process declarations.
  """
  use ExUnit.Case

  alias Commonplace.Process.Config

  describe "parsing process entries" do
    test "parses a minimal elixir process entry" do
      json = %{
        "my_worker" => %{
          "mode" => "elixir",
          "source" => "worker.exs"
        }
      }

      entries = Config.parse(json)
      assert length(entries) == 1

      entry = hd(entries)
      assert entry.name == "my_worker"
      assert entry.mode == :elixir
      assert entry.source == "worker.exs"
      assert entry.restart == :permanent
      assert entry.owns == nil
    end

    test "parses all fields" do
      json = %{
        "renderer" => %{
          "mode" => "elixir",
          "source" => "render.exs",
          "restart" => "transient",
          "owns" => "output.html",
          "depends_on" => ["data_loader"]
        }
      }

      [entry] = Config.parse(json)
      assert entry.name == "renderer"
      assert entry.mode == :elixir
      assert entry.source == "render.exs"
      assert entry.restart == :transient
      assert entry.owns == "output.html"
      assert entry.depends_on == ["data_loader"]
    end

    test "parses multiple entries" do
      json = %{
        "alpha" => %{"mode" => "elixir", "source" => "a.exs"},
        "beta" => %{"mode" => "elixir", "source" => "b.exs"}
      }

      entries = Config.parse(json)
      assert length(entries) == 2
      names = Enum.map(entries, & &1.name) |> Enum.sort()
      assert names == ["alpha", "beta"]
    end

    test "handles restart strategies" do
      for {str, atom} <- [
            {"permanent", :permanent},
            {"transient", :transient},
            {"temporary", :temporary}
          ] do
        json = %{"p" => %{"mode" => "elixir", "source" => "p.exs", "restart" => str}}
        [entry] = Config.parse(json)
        assert entry.restart == atom
      end
    end

    test "returns empty list for empty config" do
      assert Config.parse(%{}) == []
    end

    test "assigns scope_uuid when provided" do
      json = %{"worker" => %{"mode" => "elixir", "source" => "w.exs"}}
      scope = "some-uuid-for-subdir"

      [entry] = Config.parse(json, scope)
      assert entry.scope_uuid == scope
    end

    test "scope_uuid is nil by default" do
      json = %{"worker" => %{"mode" => "elixir", "source" => "w.exs"}}

      [entry] = Config.parse(json)
      assert entry.scope_uuid == nil
    end
  end

  describe "diff" do
    test "detects added processes" do
      old = []
      new = [%Config{name: "worker", mode: :elixir, source: "w.exs"}]

      diff = Config.diff(old, new)
      assert diff.added == ["worker"]
      assert diff.removed == []
      assert diff.changed == []
    end

    test "detects removed processes" do
      old = [%Config{name: "worker", mode: :elixir, source: "w.exs"}]
      new = []

      diff = Config.diff(old, new)
      assert diff.added == []
      assert diff.removed == ["worker"]
    end

    test "detects changed processes" do
      old = [%Config{name: "worker", mode: :elixir, source: "v1.exs"}]
      new = [%Config{name: "worker", mode: :elixir, source: "v2.exs"}]

      diff = Config.diff(old, new)
      assert diff.added == []
      assert diff.removed == []
      assert diff.changed == ["worker"]
    end

    test "detects no changes" do
      entries = [%Config{name: "worker", mode: :elixir, source: "w.exs"}]
      diff = Config.diff(entries, entries)
      assert diff.added == []
      assert diff.removed == []
      assert diff.changed == []
    end
  end
end

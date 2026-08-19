defmodule Commonplace.MaterializeTest do
  @moduledoc """
  CX-t7te (sub-bead i of CX-q15o M2): substrate-tier materialize primitive.

  Per consensus #3168 → #3172: substrate-agnostic primitive that takes
  entries (list of decoded JSON maps) + rules (config map with
  `chains:` key) → materialized output. Two enumerated chain semantics:
  `:latest_replaces` (chain tip's non-pointer fields override original;
  adds `edited?` + `edited_at` flags) and `:marks_deleted` (presence
  of any chain link → `deleted?` true).

  These tests exercise the primitive on SYNTHETIC non-chat fixtures
  (revision-tracked tasks) to prove the substrate primitive isn't
  chat-specific. Chat's existing materialize behavior is verified
  unchanged by the existing chat/messages_test.exs (sub-bead ii).
  """
  use ExUnit.Case, async: true

  alias Commonplace.Materialize

  # Synthetic fixture: a "revision-tracked task" log shape, semantically
  # identical to chat's edit/tombstone chains but with completely
  # different field names — proves the primitive is domain-agnostic.
  #
  # `revises` mirrors `edit_of` (latest_replaces): later revisions
  # override the original's fields.
  # `cancels` mirrors `tombstone_of` (marks_deleted): any cancellation
  # marks the original as deleted? true.
  @task_rules %{
    chains: [
      %{field: "revises", semantics: :latest_replaces},
      %{field: "cancels", semantics: :marks_deleted}
    ]
  }

  describe "materialize/2 — single original, no chains" do
    test "passthrough fields preserved verbatim" do
      entries = [
        %{"id" => "t1", "title" => "Write report", "owner" => "alice", "ts" => "T0"}
      ]

      [task] = Materialize.materialize(entries, @task_rules)

      assert task["id"] == "t1"
      assert task["title"] == "Write report"
      assert task["owner"] == "alice"
      assert task["ts"] == "T0"
      assert task["deleted?"] == false
      assert task["edited?"] == false
      refute Map.has_key?(task, "edited_at")
    end
  end

  describe "materialize/2 — :latest_replaces chains" do
    test "single revision: tip's title overrides original; edited?=true; edited_at=tip ts" do
      entries = [
        %{"id" => "t1", "title" => "v1", "owner" => "alice", "ts" => "T0"},
        %{"id" => "t1-r1", "title" => "v2", "ts" => "T1", "revises" => "t1"}
      ]

      [task] = Materialize.materialize(entries, @task_rules)

      assert task["id"] == "t1"

      assert task["title"] == "v2",
             "latest revision's title replaces original's"

      assert task["owner"] == "alice", "passthrough fields not in revision survive"
      assert task["edited?"] == true
      assert task["edited_at"] == "T1"
    end

    test "multiple revisions: latest wins by array position" do
      entries = [
        %{"id" => "t1", "title" => "v1", "ts" => "T0"},
        %{"id" => "t1-r1", "title" => "v2", "ts" => "T1", "revises" => "t1"},
        %{"id" => "t1-r2", "title" => "v3", "ts" => "T2", "revises" => "t1"}
      ]

      [task] = Materialize.materialize(entries, @task_rules)

      assert task["title"] == "v3"
      assert task["edited_at"] == "T2"
    end

    test "depth-2 chain: revision-of-revision resolves to root original" do
      entries = [
        %{"id" => "t1", "title" => "v1", "ts" => "T0"},
        %{"id" => "rev-A", "title" => "v2", "ts" => "T1", "revises" => "t1"},
        %{"id" => "rev-B", "title" => "v3", "ts" => "T2", "revises" => "rev-A"}
      ]

      [task] = Materialize.materialize(entries, @task_rules)

      assert task["id"] == "t1"
      assert task["title"] == "v3", "depth-2 chain tip wins"
      assert task["edited_at"] == "T2"
    end
  end

  describe "materialize/2 — :marks_deleted chains" do
    test "single cancellation marks the task deleted" do
      entries = [
        %{"id" => "t1", "title" => "secret", "ts" => "T0"},
        %{"id" => "t1-c1", "ts" => "T1", "cancels" => "t1"}
      ]

      [task] = Materialize.materialize(entries, @task_rules)

      assert task["id"] == "t1"
      assert task["deleted?"] == true
    end

    test "concurrent cancellations converge — second cancel is harmless" do
      entries = [
        %{"id" => "t1", "title" => "data", "ts" => "T0"},
        %{"id" => "c1", "ts" => "T1", "cancels" => "t1"},
        %{"id" => "c2", "ts" => "T2", "cancels" => "t1"}
      ]

      [task] = Materialize.materialize(entries, @task_rules)
      assert task["deleted?"] == true
    end

    test "cancellation of a revision deletes the original (chain resolution)" do
      entries = [
        %{"id" => "t1", "title" => "v1", "ts" => "T0"},
        %{"id" => "rev", "title" => "v2", "ts" => "T1", "revises" => "t1"},
        %{"id" => "cancel", "ts" => "T2", "cancels" => "rev"}
      ]

      [task] = Materialize.materialize(entries, @task_rules)

      assert task["id"] == "t1"

      assert task["deleted?"] == true,
             "cancel→revises→t1 chain ultimately marks t1 deleted"
    end
  end

  describe "materialize/2 — both chain types together" do
    test "edited and deleted both true" do
      entries = [
        %{"id" => "t1", "title" => "v1", "ts" => "T0"},
        %{"id" => "rev", "title" => "v2", "ts" => "T1", "revises" => "t1"},
        %{"id" => "cancel", "ts" => "T2", "cancels" => "t1"}
      ]

      [task] = Materialize.materialize(entries, @task_rules)
      assert task["edited?"] == true
      assert task["deleted?"] == true
      assert task["title"] == "v2"
    end
  end

  describe "materialize/2 — orphan filtering" do
    test "chain links pointing at non-existent ids are filtered out" do
      entries = [
        %{"id" => "t1", "title" => "real", "ts" => "T0"},
        %{"id" => "orphan-rev", "title" => "?", "ts" => "T1", "revises" => "ghost"},
        %{"id" => "orphan-cancel", "ts" => "T2", "cancels" => "ghost"}
      ]

      ids = Materialize.materialize(entries, @task_rules) |> Enum.map(& &1["id"])

      assert ids == ["t1"],
             "orphan chain links must not surface as originals or affect existing originals"
    end
  end

  describe "materialize/2 — multiple originals" do
    test "preserves array order; each original materialized independently" do
      entries = [
        %{"id" => "t1", "title" => "first", "ts" => "T0"},
        %{"id" => "t2", "title" => "second", "ts" => "T1"},
        %{"id" => "t3", "title" => "third", "ts" => "T2"},
        %{"id" => "t1-r1", "title" => "first-revised", "ts" => "T3", "revises" => "t1"}
      ]

      result = Materialize.materialize(entries, @task_rules)
      ids = Enum.map(result, & &1["id"])
      assert ids == ["t1", "t2", "t3"]

      [t1, t2, t3] = result
      assert t1["title"] == "first-revised"
      assert t1["edited?"] == true
      assert t2["title"] == "second"
      assert t2["edited?"] == false
      assert t3["title"] == "third"
    end
  end

  describe "materialize/2 — cycle safety" do
    test "self-referencing chain link doesn't infinite-loop" do
      entries = [
        %{"id" => "t1", "title" => "real", "ts" => "T0"},
        %{"id" => "self", "title" => "loop", "ts" => "T1", "revises" => "self"}
      ]

      # Self-cycle is an orphan (its chain root is itself, not t1) — filtered.
      ids = Materialize.materialize(entries, @task_rules) |> Enum.map(& &1["id"])
      assert ids == ["t1"]
    end

    test "two-link cycle doesn't infinite-loop" do
      entries = [
        %{"id" => "t1", "title" => "real", "ts" => "T0"},
        %{"id" => "a", "ts" => "T1", "revises" => "b"},
        %{"id" => "b", "ts" => "T2", "revises" => "a"}
      ]

      ids = Materialize.materialize(entries, @task_rules) |> Enum.map(& &1["id"])
      assert ids == ["t1"], "cyclic chain (a↔b) must terminate without crashing"
    end
  end

  describe "materialize/2 — empty rules" do
    test "no chains rules → every entry is its own original; no chain-derived fields" do
      entries = [
        %{"id" => "x", "title" => "alpha"},
        %{"id" => "y", "title" => "beta", "revises" => "x"}
      ]

      result = Materialize.materialize(entries, %{chains: []})
      ids = Enum.map(result, & &1["id"])

      assert ids == ["x", "y"],
             "with no chain rules, both entries surface as originals"

      Enum.each(result, fn r ->
        refute Map.has_key?(r, "deleted?")
        refute Map.has_key?(r, "edited?")
      end)
    end
  end
end

defmodule Commonplace.Chat.MessagesTest do
  @moduledoc """
  CX-sacn (D1 of CX-p2qp): pure data layer for chat messages.

  Per chat-room.md (a5f3f5e on commonplace-plan/main), `_messages` is a
  top-level YArray of JSON-encoded entries. Edits and deletes APPEND new
  entries; readers walk forward through edit_of/tombstone_of chains to
  compute current state. This module owns the JSON shape contract and
  the materialize/1 walk.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Chat.Messages

  describe "new/0" do
    test "returns a fresh doc with the _messages YArray top-level type" do
      doc = Messages.new()
      assert Messages.list(doc) == []
    end
  end

  describe "append/2 + list/1" do
    test "append + list round-trips a single entry" do
      doc = Messages.new()

      entry = %{
        "id" => "m1",
        "ts" => "2026-04-25T19:00:00Z",
        "author_signer_id" => "alice@aaaaaaaa",
        "author_path" => "alice.usr",
        "text" => "hello"
      }

      doc = Messages.append(doc, entry)

      assert Messages.list(doc) == [entry]
    end

    test "preserves insertion order across multiple appends" do
      doc =
        Messages.new()
        |> Messages.append(%{"id" => "m1", "text" => "first"})
        |> Messages.append(%{"id" => "m2", "text" => "second"})
        |> Messages.append(%{"id" => "m3", "text" => "third"})

      ids = Messages.list(doc) |> Enum.map(& &1["id"])
      assert ids == ["m1", "m2", "m3"]
    end

    test "atom-keyed maps round-trip as string keys (Jason normalizes on encode)" do
      doc = Messages.new()
      doc = Messages.append(doc, %{id: "m1", text: "hi", ts: "2026-04-25T19:00:00Z"})

      [entry] = Messages.list(doc)
      assert entry["id"] == "m1"
      assert entry["text"] == "hi"
      assert entry["ts"] == "2026-04-25T19:00:00Z"
    end
  end

  describe "materialize/1" do
    test "messages with no edits or tombstones are returned as-is" do
      doc =
        Messages.new()
        |> Messages.append(%{"id" => "m1", "text" => "alpha"})
        |> Messages.append(%{"id" => "m2", "text" => "beta"})

      [a, b] = Messages.materialize(doc)

      assert a["id"] == "m1"
      assert a["text"] == "alpha"
      assert a["deleted?"] == false
      assert a["edited?"] == false
      refute Map.has_key?(a, "edited_at")

      assert b["id"] == "m2"
      assert b["text"] == "beta"
    end

    test "edit entries replace the target's text and set edited?/edited_at" do
      doc =
        Messages.new()
        |> Messages.append(%{
          "id" => "m1",
          "ts" => "2026-04-25T19:00:00Z",
          "text" => "v1"
        })
        |> Messages.append(%{
          "id" => "m1-edit-a",
          "ts" => "2026-04-25T19:00:05Z",
          "text" => "v2",
          "edit_of" => "m1"
        })

      [m] = Messages.materialize(doc)

      assert m["id"] == "m1"

      assert m["text"] == "v2",
             "latest edit's text replaces the original's text"

      assert m["edited?"] == true
      assert m["edited_at"] == "2026-04-25T19:00:05Z"
    end

    test "multiple edits — last edit wins" do
      doc =
        Messages.new()
        |> Messages.append(%{"id" => "m1", "ts" => "T0", "text" => "v1"})
        |> Messages.append(%{"id" => "m1-e1", "ts" => "T1", "text" => "v2", "edit_of" => "m1"})
        |> Messages.append(%{"id" => "m1-e2", "ts" => "T2", "text" => "v3", "edit_of" => "m1"})

      [m] = Messages.materialize(doc)
      assert m["text"] == "v3"
      assert m["edited_at"] == "T2"
    end

    test "tombstone entries mark the target as deleted? = true" do
      doc =
        Messages.new()
        |> Messages.append(%{"id" => "m1", "text" => "secret"})
        |> Messages.append(%{"id" => "m1-tomb", "tombstone_of" => "m1"})

      [m] = Messages.materialize(doc)

      assert m["id"] == "m1"
      assert m["deleted?"] == true
    end

    test "concurrent tombstones converge — second tombstone is harmless" do
      doc =
        Messages.new()
        |> Messages.append(%{"id" => "m1", "text" => "data"})
        |> Messages.append(%{"id" => "tomb-a", "tombstone_of" => "m1"})
        |> Messages.append(%{"id" => "tomb-b", "tombstone_of" => "m1"})

      [m] = Messages.materialize(doc)
      assert m["deleted?"] == true
    end

    test "edit + tombstone race — deleted wins (any tombstone hides the message, monotone)" do
      doc =
        Messages.new()
        |> Messages.append(%{"id" => "m1", "ts" => "T0", "text" => "v1"})
        |> Messages.append(%{"id" => "edit", "ts" => "T2", "text" => "v2", "edit_of" => "m1"})
        |> Messages.append(%{"id" => "tomb", "ts" => "T1", "tombstone_of" => "m1"})

      [m] = Messages.materialize(doc)
      # Tombstone wins regardless of relative timestamps — deletion is monotone.
      assert m["deleted?"] == true
      # Edit text still visible (UI may render with strikethrough), but
      # the deleted? flag is the source of truth for "should I render".
      assert m["text"] == "v2"
    end

    test "edits and tombstones for non-existent message_ids are filtered out" do
      doc =
        Messages.new()
        |> Messages.append(%{"id" => "m1", "text" => "real"})
        |> Messages.append(%{"id" => "orphan-edit", "edit_of" => "ghost", "text" => "?"})
        |> Messages.append(%{"id" => "orphan-tomb", "tombstone_of" => "ghost"})

      result = Messages.materialize(doc)

      ids = Enum.map(result, & &1["id"])

      assert ids == ["m1"],
             "orphan edits/tombstones referencing missing ids must not appear in the output"
    end

    # Plan-bot edge cases (msg #3028) — exercising the chain-walking
    # semantics implied by the spec's "edit_of chain" + "monotone" wording.

    test "edit-of-edit (depth-2 chain): tip's text wins, edited_at is the tip's ts" do
      doc =
        Messages.new()
        |> Messages.append(%{"id" => "m1", "ts" => "T0", "text" => "v1"})
        |> Messages.append(%{"id" => "edit-A", "ts" => "T1", "text" => "v2", "edit_of" => "m1"})
        |> Messages.append(%{
          "id" => "edit-B",
          "ts" => "T2",
          "text" => "v3",
          "edit_of" => "edit-A"
        })

      [m] = Messages.materialize(doc)

      assert m["id"] == "m1"

      assert m["text"] == "v3",
             "depth-2 edit chain: edit-B (whose edit_of points at edit-A which points at m1) " <>
               "is the tip; its text wins"

      assert m["edited?"] == true
      assert m["edited_at"] == "T2"
    end

    test "tombstone-of-tombstone: harmless no-op (monotone — already-deleted stays deleted)" do
      doc =
        Messages.new()
        |> Messages.append(%{"id" => "m1", "text" => "data"})
        |> Messages.append(%{"id" => "tomb-1", "tombstone_of" => "m1"})
        |> Messages.append(%{"id" => "tomb-2", "tombstone_of" => "tomb-1"})

      [m] = Messages.materialize(doc)

      assert m["deleted?"] == true,
             "tombstone-of-tombstone composes — m1 stays deleted"
    end

    test "tombstone of an edit deletes the original (chain resolution)" do
      doc =
        Messages.new()
        |> Messages.append(%{"id" => "m1", "text" => "v1"})
        |> Messages.append(%{"id" => "edit", "text" => "v2", "edit_of" => "m1"})
        |> Messages.append(%{"id" => "tomb", "tombstone_of" => "edit"})

      [m] = Messages.materialize(doc)
      assert m["id"] == "m1"

      assert m["deleted?"] == true,
             "tombstone whose chain ultimately points at m1 (via the edit) deletes m1"
    end
  end

  describe "materialize/1 passthrough" do
    test "preserves passthrough fields (author, ts, reply_to)" do
      doc =
        Messages.new()
        |> Messages.append(%{
          "id" => "m1",
          "ts" => "T0",
          "author_signer_id" => "alice@aaaaaaaa",
          "author_path" => "alice.usr",
          "text" => "hi",
          "reply_to" => "m0"
        })

      [m] = Messages.materialize(doc)

      assert m["ts"] == "T0"
      assert m["author_signer_id"] == "alice@aaaaaaaa"
      assert m["author_path"] == "alice.usr"
      assert m["reply_to"] == "m0"
    end
  end
end

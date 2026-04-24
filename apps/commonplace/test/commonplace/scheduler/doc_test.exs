defmodule Commonplace.Scheduler.DocTest do
  @moduledoc """
  CX-6av: scheduler state lives in a CRDT doc under `__system/scheduler`.
  This module holds the schedule entries in a top-level YMap named
  `schedules`, keyed by schedule_id. Each value is a JSON-encoded
  `{fire_at, target_topic, payload, status}` record. The doc IS the
  schedule DB — no external persistence.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Scheduler.Doc

  describe "new/0 + put/3 + get/2" do
    test "empty doc returns :error for unknown id" do
      assert :error = Doc.get(Doc.new(), "nope")
    end

    test "put then get round-trips a full entry" do
      entry = %{
        "fire_at" => "2026-04-24T12:00:00Z",
        "target_topic" => "work/done",
        "payload" => %{"msg" => "time"},
        "status" => "pending"
      }

      doc = Doc.put(Doc.new(), "id-1", entry)
      assert {:ok, ^entry} = Doc.get(doc, "id-1")
    end

    test "second put with the same id overwrites" do
      first = entry("2026-04-24T12:00:00Z", "pending")
      second = entry("2026-04-24T12:00:00Z", "fired")

      doc =
        Doc.new()
        |> Doc.put("id-1", first)
        |> Doc.put("id-1", second)

      assert {:ok, ^second} = Doc.get(doc, "id-1")
    end
  end

  describe "all/1" do
    test "returns an empty map for a fresh doc" do
      assert %{} == Doc.all(Doc.new())
    end

    test "returns all id → entry pairs" do
      doc =
        Doc.new()
        |> Doc.put("a", entry("2026-04-24T12:00:00Z", "pending"))
        |> Doc.put("b", entry("2026-04-24T13:00:00Z", "fired"))

      all = Doc.all(doc)
      assert map_size(all) == 2
      assert all["a"]["status"] == "pending"
      assert all["b"]["status"] == "fired"
    end
  end

  describe "pending/1" do
    test "returns only entries with status=pending" do
      doc =
        Doc.new()
        |> Doc.put("p1", entry("2026-04-24T12:00:00Z", "pending"))
        |> Doc.put("f1", entry("2026-04-24T13:00:00Z", "fired"))
        |> Doc.put("c1", entry("2026-04-24T14:00:00Z", "cancelled"))
        |> Doc.put("p2", entry("2026-04-24T15:00:00Z", "pending"))

      pending = Doc.pending(doc) |> Map.new()
      assert map_size(pending) == 2
      assert Map.has_key?(pending, "p1")
      assert Map.has_key?(pending, "p2")
    end

    test "returns an empty list when nothing is pending" do
      doc = Doc.put(Doc.new(), "f1", entry("2026-04-24T12:00:00Z", "fired"))
      assert [] = Doc.pending(doc)
    end
  end

  describe "round-trip through commit store encoding" do
    alias Yelixer.Encoding

    test "encode_update + apply_update preserves all entries" do
      doc =
        Doc.new()
        |> Doc.put("a", entry("2026-04-24T12:00:00Z", "pending"))
        |> Doc.put("b", entry("2026-04-24T13:00:00Z", "fired"))

      update = Encoding.encode_update(doc)
      {:ok, doc2} = Encoding.apply_update(Doc.new(), update)

      assert Doc.all(doc) == Doc.all(doc2)
    end
  end

  defp entry(fire_at, status) do
    %{
      "fire_at" => fire_at,
      "target_topic" => "t",
      "payload" => %{},
      "status" => status
    }
  end
end

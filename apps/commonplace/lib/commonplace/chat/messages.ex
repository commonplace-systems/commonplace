defmodule Commonplace.Chat.Messages do
  @moduledoc """
  Pure data layer for a chat-room `_messages` doc — the (β-revised)
  shape from chat-room.md (commit a5f3f5e on commonplace-plan/main):
  a top-level `Yelixer.Types.Array` of JSON-encoded message entries.

  This module owns the JSON shape contract and the `materialize/1` walk
  that resolves edit/tombstone chains into the "current" view that the
  view-chrome (CX-71o3) renders. Action handlers (V2 post_message, V3
  edit_message + delete_message) call `append/2` with structured maps;
  this module Jason-encodes them.

  Why the shape: see chat-room.md "Why JSON-encoded entries, not nested
  YMaps" — Yelixer's `Doc.snapshot_update/1` doesn't replay sub-types
  nested inside maps/arrays, so we keep `_messages` as a flat YArray of
  immutable JSON strings. Edits and deletes APPEND new entries; readers
  walk forward via `edit_of` / `tombstone_of` chains. CX-e2k8 (S1) smoke-
  tested the shape's snapshot-roundtrip survival; this module is the
  consumer.

  ## Entry schema

      %{
        "id"               => "<uuid v4>",            # required
        "ts"               => "<iso8601>",            # wall-clock at compose, hint only
        "author_signer_id" => "<ed25519 signer id>",  # placeholder until CX-88mw
        "author_path"      => "<presence DocRef>",    # e.g. "alice.usr"
        "text"             => "...",                  # original or edit text; absent on tombstones
        "reply_to"         => "<message_id>",         # optional, flat threading
        "edit_of"          => "<prior_id>",           # set on edit-entries
        "tombstone_of"     => "<prior_id>"            # set on delete-entries
      }

  ## Chain resolution semantics

  Both `edit_of` and `tombstone_of` resolve TRANSITIVELY: an edit whose
  `edit_of` points at another edit (depth-2 chain) is recognized as
  modifying the original message. A tombstone whose `tombstone_of`
  points at an edit deletes the original. The walk gathers all entries
  whose chain ultimately roots at a given message_id, then:

    * `text` ← latest non-tombstone entry's text in the chain (by array
      position)
    * `edited?` ← true iff any edit entry roots at this id
    * `edited_at` ← latest edit entry's ts in the chain
    * `deleted?` ← true iff any tombstone roots at this id (monotone)

  Orphan edits/tombstones (whose chain ultimately points at an id that
  isn't an original message) are filtered from the output rather than
  silently mutating an unrelated message.
  """

  alias Yelixer.{Doc, Types.Array}

  @type_name "_messages"

  @doc "Create a fresh `_messages` doc with the YArray top-level type registered."
  def new do
    doc = Doc.new()
    {doc, _} = Doc.get_or_create_type(doc, @type_name, :array)
    doc
  end

  @doc """
  Append a message entry to the YArray. The entry is Jason-encoded.
  Atom-keyed maps round-trip as string-keyed (Jason normalizes).
  """
  def append(%Doc{} = doc, %{} = entry) do
    Array.push(doc, @type_name, [Jason.encode!(entry)])
  end

  @doc """
  Read all entries verbatim, in array order, JSON-decoded back to maps.
  Use this when you want the raw appended record (for audit log,
  history view, etc.). Use `materialize/1` for the rendered "current
  state" view.
  """
  def list(%Doc{} = doc) do
    doc
    |> Array.to_list(@type_name)
    |> Enum.map(&Jason.decode!/1)
  end

  @doc """
  Walk edit/tombstone chains to produce the current rendered view —
  one map per ORIGINAL message (entries with no `edit_of` and no
  `tombstone_of`), with `text` set to the chain tip's text,
  `edited?` / `edited_at` / `deleted?` flags computed.

  See module docstring for chain-resolution semantics.
  """
  def materialize(%Doc{} = doc) do
    entries = list(doc)
    indexed = Enum.with_index(entries)
    by_id = Map.new(indexed, fn {entry, idx} -> {entry["id"], {entry, idx}} end)

    # Compute root_of/1 for every entry: walk edit_of/tombstone_of links
    # until landing on an entry that is itself an original (no chain
    # pointer) and exists in by_id. Entries whose chain doesn't terminate
    # at a known original are orphans; they produce no root.
    roots =
      Enum.reduce(indexed, %{}, fn {entry, _idx}, acc ->
        case resolve_root(entry, by_id, MapSet.new()) do
          {:ok, root_id} -> Map.put(acc, entry["id"], root_id)
          :orphan -> acc
        end
      end)

    # Group every entry's id by the root it resolves to. Originals also
    # appear in the group keyed by their own id so the chain-tip pick
    # has the original entry as a fallback when no edits exist.
    grouped =
      Enum.reduce(indexed, %{}, fn {entry, idx}, acc ->
        case Map.get(roots, entry["id"]) do
          nil ->
            acc

          root_id ->
            Map.update(acc, root_id, [{entry, idx}], &[{entry, idx} | &1])
        end
      end)

    # Emit one rendered map per original, in original-array-position
    # order so the thread reads top-to-bottom in the order originals
    # were posted.
    indexed
    |> Enum.filter(fn {entry, _} -> original?(entry) end)
    |> Enum.map(fn {original, _idx} ->
      chain = Map.get(grouped, original["id"], []) |> Enum.sort_by(fn {_, idx} -> idx end)
      render(original, chain)
    end)
  end

  # --- Private ---

  defp original?(entry) do
    not Map.has_key?(entry, "edit_of") and not Map.has_key?(entry, "tombstone_of")
  end

  defp resolve_root(entry, by_id, seen) do
    cond do
      MapSet.member?(seen, entry["id"]) ->
        # Cycle — treat as orphan to avoid infinite loop.
        :orphan

      original?(entry) ->
        if Map.has_key?(by_id, entry["id"]), do: {:ok, entry["id"]}, else: :orphan

      true ->
        target_id = entry["edit_of"] || entry["tombstone_of"]

        case Map.get(by_id, target_id) do
          {parent, _idx} ->
            resolve_root(parent, by_id, MapSet.put(seen, entry["id"]))

          nil ->
            :orphan
        end
    end
  end

  defp render(original, chain) do
    edits =
      chain
      |> Enum.filter(fn {e, _} -> Map.has_key?(e, "edit_of") end)

    tombstones =
      chain
      |> Enum.filter(fn {e, _} -> Map.has_key?(e, "tombstone_of") end)

    deleted? = tombstones != []
    edited? = edits != []

    # Latest edit by array position wins. If no edits, text comes from
    # the original. If a partial-chain edit drops `text` (defensive — a
    # malformed actor could omit it), fall back to the previous entry.
    text =
      case edits do
        [] ->
          Map.get(original, "text")

        _ ->
          {edit, _} = Enum.max_by(edits, fn {_, idx} -> idx end)
          Map.get(edit, "text") || Map.get(original, "text")
      end

    edited_at =
      case edits do
        [] ->
          nil

        _ ->
          {edit, _} = Enum.max_by(edits, fn {_, idx} -> idx end)
          Map.get(edit, "ts")
      end

    base = %{
      "id" => original["id"],
      "text" => text,
      "deleted?" => deleted?,
      "edited?" => edited?
    }

    base =
      Enum.reduce(["ts", "author_signer_id", "author_path", "reply_to"], base, fn key, acc ->
        case Map.get(original, key) do
          nil -> acc
          value -> Map.put(acc, key, value)
        end
      end)

    if edited_at, do: Map.put(base, "edited_at", edited_at), else: base
  end
end

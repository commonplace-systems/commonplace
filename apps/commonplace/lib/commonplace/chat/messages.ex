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

  alias Commonplace.Document.ContentType
  alias Yelixer.{Doc, Types.Array}

  # CX-0trq: _messages is a ContentType :array envelope — `_root` YMap
  # carries `_type="array"` + `_name="_messages"` metadata, the actual
  # YArray lives under the registered "content" type. cat now returns
  # the JSON-string entries; introspection tools that route through
  # ContentType.get_type/get_content/get_meta light up.
  #
  # The named array's KEY inside the doc is "content" (ContentType's
  # convention); the doc's display name is "_messages" (set in `_root`).
  # Callers continue using `Messages.append/list/materialize` and don't
  # see this layer.
  @display_name "_messages"
  @content_type "content"

  @doc "Create a fresh `_messages` doc with the ContentType :array envelope."
  def new do
    doc = Doc.new()
    ContentType.create(doc, :array, @display_name)
  end

  @doc """
  Append a message entry to the YArray. The entry is Jason-encoded.
  Atom-keyed maps round-trip as string-keyed (Jason normalizes).
  """
  def append(%Doc{} = doc, %{} = entry) do
    Array.push(doc, @content_type, [Jason.encode!(entry)])
  end

  @doc """
  Read all entries verbatim, in array order, JSON-decoded back to maps.
  Use this when you want the raw appended record (for audit log,
  history view, etc.). Use `materialize/1` for the rendered "current
  state" view.
  """
  def list(%Doc{} = doc) do
    doc
    |> Array.to_list(@content_type)
    |> Enum.map(&Jason.decode!/1)
  end

  @doc """
  Walk edit/tombstone chains to produce the current rendered view —
  one map per ORIGINAL message (entries with no `edit_of` and no
  `tombstone_of`), with chain-tip's text replacing the original's,
  `edited?` / `edited_at` / `deleted?` flags computed.

  CX-7kl3 (M3 sub-bead ii): chain rules live in
  `Commonplace.Chat.ChatViewCompute.chain_rules/0` (the chat compute
  spec), not inline here — substrate-pure direction. This delegates to
  the substrate primitive with the rules from there. Existing callers
  (ChatRoomLive, integration tests) get the same materialized-list
  shape they always did.
  """
  def materialize(%Doc{} = doc) do
    Commonplace.Materialize.materialize(
      list(doc),
      Commonplace.Chat.ChatViewCompute.chain_rules()
    )
  end
end

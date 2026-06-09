defmodule Commonplace.Document.Rebase do
  @moduledoc """
  Positional-rebase dispatcher for the commonplace document envelope
  (Phase 1 of CX-6a7 — YText only).

  ## Why "positional"

  When a remote snapshot arrives it re-encodes the whole document under
  *fresh* item IDs (a new epoch — a fresh identity space; see
  `Commonplace.Document.Server`). A live document may carry uncommitted
  *dirty* edits — local edits made after the most-recent committed state
  and not yet committed — authored against the *old* item identities.
  Those edits cannot simply be replayed onto the snapshot: the CRDT items
  they targeted by ID do not exist in the fresh doc. So instead of
  replaying the original ID-bound operations, we recover *what the dirty
  edits did* — by diffing the pre-dirty committed content against the
  dirty content — and re-apply that effect *by position*: an index for
  text/array, a key for map. Identity-independent replay is what
  "positional" means here, and it is why a 2-way content diff is the
  right tool — the `pre` baseline (below) is what makes that diff capture
  exactly the local edits.

  Given `old_doc` (pre-dirty committed state), `dirty_doc` (committed +
  local dirty edits), and `new_doc` (fresh doc after applying a remote
  snapshot), re-author the dirty edits as positional ops on `new_doc`.

  Only the envelope's `content` type is rebased; the envelope root YMap
  (`_type`, `_name`) is treated as non-edit-tracked. `:text`, `:map`,
  `:array`, and `:xml` content are all rebased via their per-type
  primitives. Any other content type returns `{:error, {:unsupported_type,
  kind}}` (all-or-nothing semantics with no silent fallback).

  The rebase baseline `pre` is reconstructed from `parent_commit`.
  `Commonplace.Document.Server` advances `parent_commit` whenever a
  remote-incremental commit is applied (CX-bgq), so `pre` always
  reflects the most recent incorporated committed state and the 2-way
  diff `(pre, dirty)` captures only local dirty edits.

  See `docs/positional-rebase.md` (commonplace-plan repo) for the full
  RFC and vocabulary.
  """

  alias Commonplace.Document.ContentType
  alias Commonplace.Document.Rebase.{YText, YMap, YArray, YXml}
  alias Yelixer.Doc

  @type error ::
          {:unsupported_type, nil | atom()}
          | YText.error()
          | YArray.error()
          | YXml.error()

  @spec rebase(Doc.t(), Doc.t(), Doc.t()) :: {:ok, Doc.t()} | {:error, error()}
  def rebase(%Doc{} = old_doc, %Doc{} = dirty_doc, %Doc{} = new_doc) do
    pre = ContentType.get_content(old_doc)
    dirty = ContentType.get_content(dirty_doc)

    if pre == dirty do
      # No dirty content edits — snapshot applies cleanly regardless of type.
      {:ok, new_doc}
    else
      case ContentType.get_type(dirty_doc) do
        :text -> YText.rebase(pre || "", dirty || "", new_doc, "content")
        :map -> YMap.rebase(pre || %{}, dirty || %{}, new_doc, "content")
        :array -> YArray.rebase(pre || [], dirty || [], new_doc, "content")
        :xml -> YXml.rebase(pre || [], dirty || [], new_doc, "content")
        other -> {:error, {:unsupported_type, other}}
      end
    end
  end
end

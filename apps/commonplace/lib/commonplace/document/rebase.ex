defmodule Commonplace.Document.Rebase do
  @moduledoc """
  Positional-rebase dispatcher for the commonplace document envelope
  (Phase 1 of CX-6a7 — YText only).

  Given `old_doc` (pre-dirty committed state), `dirty_doc` (committed +
  local dirty edits), and `new_doc` (fresh doc after applying a remote
  snapshot), re-author the dirty edits as positional ops on `new_doc`.

  Only the envelope's `content` type is rebased; the envelope root YMap
  (`_type`, `_name`) is treated as non-edit-tracked (Phase 3 / YMap
  rebase will handle metadata if needed). Non-`:text` content types
  return `{:error, {:unsupported_type, kind}}` — all-or-nothing
  semantics with no silent fallback.

  Known limitation (documented, deferred): the 2-way diff `(pre, dirty)`
  treats any remote incremental commits applied to `dirty_doc` between
  `parent_commit` and the snapshot as if they were local dirty edits.
  If the incoming snapshot already contains those same incrementals,
  replaying the diff on `new_doc` will double-apply them. Phase 1
  accepts this edge case; a follow-on bead will advance `parent_commit`
  on remote-incremental apply to bound `pre` tightly.

  See `docs/positional-rebase.md` (commonplace-plan repo) for the full
  RFC and vocabulary.
  """

  alias Commonplace.Document.ContentType
  alias Commonplace.Document.Rebase.YText
  alias Yelixer.Doc

  @type error ::
          {:unsupported_type, :map | :array | :xml | nil}
          | YText.error()

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
        other -> {:error, {:unsupported_type, other}}
      end
    end
  end
end

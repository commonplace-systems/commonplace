defmodule Commonplace.Document.Rebase do
  @moduledoc """
  Positional-rebase dispatcher for the commonplace document envelope
  (Phase 1 of CX-6a7 — YText only).

  Given `old_doc` (pre-dirty committed state), `dirty_doc` (committed +
  local dirty edits), and `new_doc` (fresh doc after applying a remote
  snapshot), re-author the dirty edits as positional ops on `new_doc`.

  Only the envelope's `content` type is rebased; the envelope root YMap
  (`_type`, `_name`) is treated as non-edit-tracked. `:text`, `:map`,
  and `:array` content are rebased via their per-type primitives;
  `:xml` returns `{:error, {:unsupported_type, kind}}` (all-or-nothing
  semantics with no silent fallback).

  The rebase baseline `pre` is reconstructed from `parent_commit`.
  `Commonplace.Document.Server` advances `parent_commit` whenever a
  remote-incremental commit is applied (CX-bgq), so `pre` always
  reflects the most recent incorporated committed state and the 2-way
  diff `(pre, dirty)` captures only local dirty edits.

  See `docs/positional-rebase.md` (commonplace-plan repo) for the full
  RFC and vocabulary.
  """

  alias Commonplace.Document.ContentType
  alias Commonplace.Document.Rebase.{YText, YMap, YArray}
  alias Yelixer.Doc

  @type error ::
          {:unsupported_type, :xml | nil}
          | YText.error()
          | YArray.error()

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
        other -> {:error, {:unsupported_type, other}}
      end
    end
  end
end

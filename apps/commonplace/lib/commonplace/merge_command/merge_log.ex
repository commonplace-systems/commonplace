defmodule Commonplace.MergeCommand.MergeLog do
  @moduledoc """
  Per-document merge log UUID derivation for leaf docs (CX-nuc2).

  When a magenta merge command's target is a schema doc, the handler
  attaches a `__merge.log` schema entry under it (see
  `Commonplace.MergeCommand.Handler.ensure_merge_log_entry/2`). That
  strategy doesn't generalize to leaf docs — there's nowhere in a Text
  doc to put a schema entry, and if you tried, the next commit on the
  chain would corrupt the leaf into a schema stub.

  Instead, the per-doc merge log lives at a UUID5-derived address. Any
  peer given the target_uuid can rediscover the log with one function
  call. Symmetric with the CX-92u mailbox derivation: deterministic,
  keyed by the natural identifier of the thing being observed, no
  parent-registry dependency.
  """

  def log_uuid_for_doc(target_uuid) when is_binary(target_uuid) do
    UUID.uuid5(:url, "urn:commonplace:merge-log:" <> target_uuid)
  end
end

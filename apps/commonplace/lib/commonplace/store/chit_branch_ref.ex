defmodule Commonplace.Store.ChitBranchRef do
  @moduledoc """
  A chit branch ref: an ORDINARY store doc whose successive commits carry
  successive head chit cids. Its `commit_log` IS the reflog-of-heads — no
  new machinery, no side index; the existing chained-commit substrate
  already gives us an append-only, signable, tamper-evident history of
  "which chit was this branch's head, in order."

  Each `advance/4` is a FULL-STATE REWRITE: a fresh map doc holding just
  `"head" => <hex cid>`, rebuilt from `Yelixer.Doc.new/1` under the
  branch doc's stable writer hand (`Commonplace.WriterHand.for_doc/1`) —
  the same shape `Commonplace.Reflog.Snapshot.build_reflog_doc/3` uses,
  and for the same CX-41qg.3 reason (a fresh random client_id per write
  would grow the state vector one slot per advance, forever). The same
  consequence follows too: successive commits reuse (client, clock)
  pairs, so this doc must NEVER be chain-replayed
  (`DocBuilder.reconstruct_doc/2` would silently stick on round 1 — see
  `Commonplace.Reflog.Restore`'s "never chain-replay a pin doc" note).
  `head/2` reads via `reconstruct_snapshot/2` (latest commit only) and
  `history/3` applies each commit's own update standalone, which are the
  two safe read shapes for full-state-rewrite chains.

  This module deliberately does NOT touch proto-chit's
  `predecessors.json` — that is a separate lane.
  """

  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{Commit, CommitStoreClient}
  alias Commonplace.Tree.DocBuilder
  alias Commonplace.WriterHand

  @head_key "head"

  @doc """
  Record `chit_cid` as the branch's new head: one new chained commit on
  `branch_doc_uuid` whose content is the head cid (hex).

  On a fresh uuid, `create_chained_commit/5` genesis-stamps the doc
  first (synthetic `%{kind: :genesis}` root) and chains this write onto
  it — no special first-advance handling needed here. Pass
  `opts[:signing_context]` to sign the ref commit (it is carried through
  unchanged; everything else in `opts` is ignored).

  Returns `{:ok, commit_id}` of the ref commit, or
  `{:error, {:branch_advance_refused, reason}}` when the store refuses
  the write (e.g. an enforce-mode gate) — never a silent success.
  """
  @spec advance(GenServer.server(), String.t(), binary(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def advance(store, branch_doc_uuid, chit_cid, opts \\ [])
      when is_binary(branch_doc_uuid) and is_binary(chit_cid) do
    hex = Base.encode16(chit_cid, case: :lower)

    doc =
      Yelixer.Doc.new(client_id: WriterHand.for_doc(branch_doc_uuid))
      |> ContentType.create(:map, "chit_branch_ref")
      |> ContentType.set_key(@head_key, hex)

    update = Yelixer.Encoding.encode_update(doc)
    commit_opts = Keyword.take(opts, [:signing_context])

    case CommitStoreClient.create_chained_commit(store, branch_doc_uuid, update, %{}, commit_opts) do
      %Commit{} = commit -> {:ok, commit.id}
      other -> {:error, {:branch_advance_refused, other}}
    end
  end

  @doc """
  The branch's current head chit cid (decoded binary), read from the
  latest ref commit only (`reconstruct_snapshot/2` — the safe read for a
  full-state-rewrite chain, see moduledoc). `:none` when the branch doc
  has no commits, or none that carry a head (e.g. only the genesis
  stamp).
  """
  @spec head(GenServer.server(), String.t()) :: {:ok, binary()} | :none
  def head(store, branch_doc_uuid) when is_binary(branch_doc_uuid) do
    case DocBuilder.reconstruct_snapshot(store, branch_doc_uuid) do
      {:ok, doc} -> decode_head(ContentType.get_content(doc))
      :none -> :none
    end
  end

  @doc """
  The reflog-of-heads: every head cid ever recorded on the branch,
  OLDEST FIRST (so `List.last(history) == head` and the list reads as
  the branch's forward narrative). Walks `commit_log` (newest-first,
  `opts[:limit]` commits — default 100), skips the synthetic genesis
  stamp, applies each ref commit's own update standalone (never
  chain-replayed — moduledoc), and reverses.

  A commit whose content carries no decodable head (foreign writes on
  the branch doc) is skipped rather than crashing the whole listing.
  """
  @spec history(GenServer.server(), String.t(), keyword()) :: [binary()]
  def history(store, branch_doc_uuid, opts \\ [limit: 100]) when is_binary(branch_doc_uuid) do
    limit = Keyword.get(opts, :limit, 100)

    CommitStoreClient.commit_log(store, branch_doc_uuid, limit: limit)
    |> Enum.reject(&genesis_commit?/1)
    |> Enum.flat_map(&commit_head_cid/1)
    |> Enum.reverse()
  end

  defp genesis_commit?(%{metadata: %{kind: :genesis}}), do: true
  defp genesis_commit?(_), do: false

  # One ref commit's recorded head, read the only safe way for this doc:
  # its own update applied alone to a throwaway fresh doc (every advance
  # is a self-contained full state by construction).
  defp commit_head_cid(commit) do
    with {:ok, doc} <- Yelixer.Encoding.apply_update(Yelixer.Doc.new(), commit.update),
         {:ok, cid} <- decode_head(ContentType.get_content(doc)) do
      [cid]
    else
      _ -> []
    end
  end

  defp decode_head(%{@head_key => hex}) when is_binary(hex) do
    case Base.decode16(hex, case: :lower) do
      {:ok, cid} -> {:ok, cid}
      :error -> :none
    end
  end

  defp decode_head(_content), do: :none
end

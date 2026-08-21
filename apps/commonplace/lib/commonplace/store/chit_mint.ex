defmodule Commonplace.Store.ChitMint do
  @moduledoc """
  The `commit -m` core: drive a reflog checkpoint of the tree, freeze it
  as a `Commonplace.Store.Chit` (tree-pin + parents + message +
  artifact-derived timestamp), store the chit, and advance the branch
  ref. One call = one narrative moment on a branch.

  ## What the pin covers

  `tree_pin` is the flat `%{doc_uuid => commit_id}` map built from the
  checkpoint's ANCHORED resolution
  (`Commonplace.Reflog.Restore.resolve_anchored/4` — the public
  ancestry-carrying seam for store-side checkpoint consumers):

    * every FILE the checkpoint recorded — the doc's own pinned commit;
    * every DIRECTORY's own schema doc, the root included — the exact
      historical `__schema_cid` commit the checkpoint recorded (this is
      what lets a verified export at the pin read the directory shapes
      themselves pinned, not at live heads);
    * plus the checkpoint anchor itself — the root reflog `__snapshot`
      doc's uuid mapped to the checkpoint commit id — so the chit alone
      re-derives the whole walk (`resolve_anchored/4` from that one pair
      reproduces everything above).

  What it does NOT cover, by construction: entries the checkpoint
  excludes at write time (`__`-prefixed meta docs, presence-transient
  suffixes like `.usr` — see `Commonplace.Reflog.Snapshot`), and a
  directory that had zero commits at checkpoint time (there is no
  schema commit to pin).

  ## F5 determinism

  `authored_at` is the checkpoint commit's own stored timestamp
  (converted to integer microseconds) — artifact-derived, never
  wall-clock read here. Combined with the checkpoint's idempotency
  cursor (CX-71ej: unchanged tree → the SAME reflog commit id, hence the
  same stored commit row, hence the same timestamp), two mints of an
  unchanged moment produce byte-identical artifacts and therefore the
  SAME cid — dedup by construction. Note the parents field is part of
  the artifact: two mints on the SAME branch necessarily differ (the
  second's parent is the first), which is correct — determinism is
  "same inputs, same cid", and the branch head is an input.
  """

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Reflog.{Restore, Snapshot}
  alias Commonplace.Store.{Chit, ChitAncestry, ChitBranchRef, CommitStoreClient}

  require Logger

  @default_owner "chit"

  @doc """
  Checkpoint the tree at `root_uuid`, mint a chit for it with `message`,
  store it, and advance `branch_doc_uuid` to it.

  Options:

    * `:owner` — the reflog owner lane the checkpoint writes under
      (default `"chit"`, keeping chit checkpoints out of the sync
      agent's `"server"` lane).
    * `:signing_context` — signs both the checkpoint/ref commits (via
      the store's normal opts threading) and the chit's envelope; when
      omitted, resolves the node identity once (same posture as
      `Snapshot.checkpoint/4`) and falls back to unsigned.

  Returns `{:ok, %Chit{}}` or `{:error, reason}` — a refused chit store
  or branch advance surfaces, never a silent half-mint.
  """
  @spec commit(GenServer.server(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Chit.t()} | {:error, term()}
  def commit(store, root_uuid, branch_doc_uuid, message, opts \\ [])
      when is_binary(root_uuid) and is_binary(branch_doc_uuid) and is_binary(message) do
    owner = Keyword.get(opts, :owner, @default_owner)

    # Resolve the signing context ONCE and pin it into opts, so the
    # checkpoint walk, the branch-ref advance, and the chit envelope all
    # use the SAME identity — never three independent resolutions that
    # could race a key rotation into a mixed-signer mint.
    signing_context = Keyword.get_lazy(opts, :signing_context, &resolve_signing_context/0)
    opts = Keyword.put(opts, :signing_context, signing_context)

    with {:ok, checkpoint_commit_id} <- Snapshot.checkpoint(root_uuid, store, owner, opts),
         {:ok, snapshot_doc_uuid} <- root_snapshot_uuid(store, root_uuid, owner),
         {:ok, anchored} <-
           Restore.resolve_anchored(store, snapshot_doc_uuid, checkpoint_commit_id, root_uuid),
         {:ok, authored_at} <- checkpoint_timestamp(store, checkpoint_commit_id) do
      # The anchored walk's flat pin, plus the checkpoint anchor pair
      # that regenerates it (moduledoc, "What the pin covers").
      tree_pin =
        anchored
        |> flatten_pin()
        |> Map.put(snapshot_doc_uuid, checkpoint_commit_id)

      # Parents: the branch's current head as a one-element narrative
      # claim, or [] for the branch's first moment.
      parents =
        case ChitBranchRef.head(store, branch_doc_uuid) do
          {:ok, head_cid} -> [head_cid]
          :none -> []
        end

      chit =
        tree_pin
        |> Chit.new(parents, author_for(signing_context), message, authored_at)
        |> maybe_sign(signing_context)

      # THE MINT GATE (primary enforcement of the ancestry invariant,
      # spec §3/[4]): verify the parent claims BEFORE the chit is stored
      # or the branch advanced — a false claim is never recorded, not
      # recorded-then-alarmed. This is mint-point construction: a mint
      # is an explicit user action, not the converge path, so refusing
      # one refuses recording a false narrative, not convergence (R4
      # preserved). The chit corpus starts EMPTY behind this gate, so no
      # backfill audit exists — every stored chit passed here. There is
      # deliberately NO override option: a diverged world mints from a
      # corrected parent instead (spec §9).
      with :ok <- ancestry_gate(store, chit),
           {:ok, _cid} <- CommitStoreClient.store_chit(store, chit),
           {:ok, _ref_commit_id} <- ChitBranchRef.advance(store, branch_doc_uuid, chit.cid, opts) do
        {:ok, chit}
      end
    end
  end

  # A genesis mint (parents == []) claims no parent moment, so there is
  # nothing to gate; ChitAncestry.check/2 short-circuits the same way,
  # but matching here keeps the gate's no-claim fast path explicit.
  defp ancestry_gate(_store, %Chit{parents: []}), do: :ok

  defp ancestry_gate(store, %Chit{} = chit) do
    case ChitAncestry.check(store, chit) do
      :ok -> :ok
      {:error, reason} -> {:error, {:ancestry_refused, reason}}
    end
  end

  # The checkpoint commit's own stored timestamp, as integer
  # microseconds — the ARTIFACT-derived `authored_at`. The commit's
  # `timestamp` field is wall-clock at commit CONSTRUCTION, but it is
  # stable per stored row: a cursor-idempotent re-checkpoint returns the
  # SAME commit id, so this read returns the SAME value — which is
  # exactly the determinism F5 needs. Never `DateTime.utc_now/0` here.
  defp checkpoint_timestamp(store, checkpoint_commit_id) do
    case CommitStoreClient.get_commit(store, checkpoint_commit_id) do
      {:ok, %{timestamp: %DateTime{} = ts}} ->
        {:ok, DateTime.to_unix(ts, :microsecond)}

      {:ok, _commit} ->
        {:error, {:checkpoint_commit_without_timestamp, checkpoint_commit_id}}

      :none ->
        {:error, {:checkpoint_commit_not_found, checkpoint_commit_id}}
    end
  end

  defp root_snapshot_uuid(store, root_uuid, owner) do
    case Restore.root_snapshot_uuid(store, root_uuid, owner) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:root_snapshot_missing, root_uuid, owner}}
    end
  end

  # Flatten resolve_anchored/4's tree into the chit's %{uuid => commit_id}
  # pin: each directory contributes its own schema pin (when it had any
  # commits at checkpoint time), each file its recorded commit.
  defp flatten_pin(%{dir_uuid: dir_uuid, schema_commit_id: schema_commit_id} = anchored) do
    base = if schema_commit_id, do: %{dir_uuid => schema_commit_id}, else: %{}

    base =
      Enum.reduce(anchored.files, base, fn {_name, {doc_uuid, commit_id}}, acc ->
        Map.put(acc, doc_uuid, commit_id)
      end)

    Enum.reduce(anchored.dirs, base, fn {_name, subtree}, acc ->
      Map.merge(acc, flatten_pin(subtree))
    end)
  end

  defp author_for(nil), do: nil

  defp author_for(%SigningContext{} = sc),
    do: Signing.signer_id(sc.identity_uuid, sc.public_key)

  defp maybe_sign(chit, nil), do: chit
  defp maybe_sign(chit, %SigningContext{} = sc), do: Chit.sign(chit, sc)

  # Same node-identity posture as Snapshot.checkpoint/4's own resolver:
  # a mint is a node-authored system operation unless the caller says
  # otherwise; a bare library-embedding/test context with no identity
  # mints unsigned rather than failing.
  defp resolve_signing_context do
    case NodeIdentity.signing_context() do
      {:ok, sc} ->
        sc

      {:error, reason} ->
        Logger.debug("ChitMint: no node identity (#{inspect(reason)}), minting unsigned")
        nil
    end
  end
end

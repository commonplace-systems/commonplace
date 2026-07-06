defmodule Commonplace.GitBridge.Inbound do
  @moduledoc """
  GitBridge G2: inbound git -> CRDT ingestion.

  Runs at the START of `GitBridge.Server`'s tick cycle (`fetch/ingest ->
  export -> sidecar -> archive -> commit -> push`). Its job is narrow:
  turn a human's git-side text edit into a real Yjs edit, merged against
  the CRDT store's current state rather than clobbering it. The CRDT
  store is ALWAYS source of truth; git text is an editable projection.

  ## The anchor-replica mechanism

  Every exported doc has a *sidecar anchor* — the commit id that was
  `:latest` the last time this bridge exported it (`Sidecar` /
  `Exporter`). That anchor is the precisely-known base for a git-side
  edit: `base` = the doc's text reconstructed AT the anchor
  (`DocBuilder.reconstruct_doc_at/3`), `theirs` = the fetched file
  content, `ours` = the doc's CURRENT live content.

  When `ours == base` (no CRDT-side edit happened since the anchor —
  the common case), the edit is unambiguous: reconstruct a REPLICA doc
  at the anchor with a stable, bridge-specific client id (mirrors
  `Sync.Agent`'s stale-write anchor-replica pattern, agent.ex
  `stable_client_id/1`), apply the whole-content grapheme-Myers diff
  (`Commonplace.Document.Diff.apply_diff/3` — base/theirs are both in
  hand, so git's line granularity never enters), encode the update, and
  mint it as a new commit chained off the anchor. Because the anchor
  IS the doc's current `:latest` in this case, chaining there is
  identical to chaining off latest — no clobber risk.

  Because the sidecar anchor is re-derived from `:latest` on EVERY
  export (this same cycle's `Exporter.export/4`, which runs right after
  this module), a successful mint here needs no separate "advance the
  anchor" step: minting moves `:latest`, and the export step immediately
  downstream re-reads `:latest` into the manifest's `anchor` field and
  `Sidecar.write/4` persists it. Same-cycle causality does the rest.

  If `ours != base` (a genuine concurrent CRDT-side edit happened since
  the anchor) AND `theirs != base`, the CRDT side wins: `theirs` is
  never applied to the doc. It is instead written to
  `<rel_path>.conflict-<shortsha>` in the worktree, where it rides the
  next export's commit, and a red `:conflict_preserved` event fires.
  Nothing is silently dropped, but nothing is silently merged either —
  reconciling two genuinely concurrent text edits is a 3-way merge
  problem this module deliberately does not attempt in v1.

  ## Eligibility gates (v1 — tight blast radius)

    * TEXT-typed docs only (sidecar `type == "text"`); `:xml` / `:map`
      / `:array` docs are rejected to the conflict path (their
      canonical render formats aren't line/char-diffable against the
      CRDT structure yet — a fast-follow, not a v1 goal).
    * git-side file ADDs and DELETEs are rejected to the conflict path
      (edits-only v1). A delete needs no repair: the doc is unchanged,
      so the very next export step regenerates the file.
    * `.commonplace/**` and `.gitattributes` are NEVER ingest-eligible
      — these are bridge-owned artifacts. A human editing them on the
      git side is silently ignored; the bridge regenerates them from
      its own state every cycle regardless.
    * A changed path absent from the sidecar manifest is rejected to
      the conflict path (unknown to the bridge, nothing to anchor to).
    * Oversized files (`max(byte_size(base), byte_size(theirs)) >`
      `:git_bridge_max_inbound_bytes`, default 2 MiB) are routed to the
      conflict path WITHOUT running Myers — a cost cap, not a
      correctness judgment.

  ## Force-push detection

  If the fetched remote head is not a descendant of the last commit
  this bridge pushed (`Git.ancestor?/3`), history was rewritten
  upstream. This module never guesses how to reconcile that: inbound
  ingestion halts for the cycle (a red `:force_push_detected` event
  fires) while export/commit/push continue undisturbed on the CRDT
  side. The very next fetch re-checks ancestry, so a force-push that
  gets un-done (or accepted by a human re-pointing the remote forward
  again) clears the halt automatically.

  ## Push-reject handling (owned by `Server`, not this module)

  Because a clean-path mint's resulting local commit chains off the
  OLD last-pushed commit (not the just-fetched remote head — this
  module never merges/rebases in git-land), the push that follows in
  the SAME cycle will usually be rejected as non-fast-forward. Per the
  reviewed design, the bridge's local git commits are DISPOSABLE
  PROJECTIONS until pushed: `Server` responds to a push rejection by
  resetting the worktree branch hard to the remote head (never
  `--force`-pushing) and lets the NEXT cycle's fetch -> ingest -> export
  -> commit -> push regenerate everything from the store, which by
  then converges to a fast-forward.

  ## Signing (non-optional) and the fourth ingress

  Every minted commit carries a signing context from the bridge's OWN
  persistent Ed25519 keypair — reusing `Commonplace.Crypto.AgentKeys`'
  existing custody pattern (node-local `SecretStore`, keyed by an
  identity uuid) rather than inventing a new key-file format: the
  bridge's identity uuid is `"git-bridge:" <> mount_uuid`,
  `AgentKeys.ensure/2` mints it idempotently, `signing_context_for/2`
  hands back the `%SigningContext{}` threaded via the `:signing_context`
  commit opt. Cert gating (proving the bridge's key is AUTHORIZED to
  write) is mode-dependent and OUT of scope here — v1 runs permissive.

  G2's minted commits are a NEW local-write ingress into the store
  (cross-ref CX-qat5.3's "fourth ingress" ledger). Every commit this
  module writes goes through `mint_edit/6` — the ONE seam — so the
  CX-qat5.3 chokepoint has a single place to add a
  `Trust.authorized?(:write)` gate when it lands, instead of scattering
  `CommitStoreClient.create_commit/6` calls through the ingest loop.
  """

  require Logger

  alias Commonplace.GitBridge.{Git, Sidecar}
  alias Commonplace.Tree.DocBuilder
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Crypto.AgentKeys
  alias Commonplace.Dataflow.PubSub

  @remote_name "origin"
  @default_max_inbound_bytes 2 * 1024 * 1024

  @doc """
  Run one inbound ingest pass.

  `state` is a plain map (deliberately NOT `GitBridge.Server`'s
  `%__MODULE__{}` — this module has no dependency on the server's
  internal shape) with:

    * `:mount_uuid`, `:repo_dir`, `:store`, `:branch` — required.
    * `:remote` — `nil` skips inbound entirely (local-only bridges).
    * `:last_pushed_commit` — the sha this bridge last reconciled
      against, or `nil` on first run (bootstraps to whatever's fetched,
      documented below — never ingests the remote's entire prior
      history as one diff on first sight).
    * `:secret_store` — passed through to `AgentKeys` (default
      `Commonplace.Store.SecretStore`).
    * `:max_inbound_bytes` — size guard override (default 2 MiB).

  Returns `{:ok, result}` where `result` is:

      %{last_pushed_commit: sha_or_nil,
        force_push_halted: boolean(),
        ingested: [%{rel_path:, uuid:, outcome: :clean | :conflict | :noop}]}
  """
  @spec run(map()) :: {:ok, map()}
  def run(%{remote: nil} = state) do
    {:ok, %{last_pushed_commit: Map.get(state, :last_pushed_commit), force_push_halted: false, ingested: []}}
  end

  def run(state) do
    repo_dir = state.repo_dir
    branch = state.branch

    case Git.fetch(repo_dir, @remote_name, branch) do
      {:ok, _} ->
        case Git.remote_ref(repo_dir, @remote_name, branch) do
          {:ok, fetched_head} -> run_with_fetched_head(state, fetched_head)
          {:error, _reason} -> unchanged(state)
        end

      {:error, reason} ->
        Logger.warning("GitBridge.Inbound: fetch failed for #{state.mount_uuid}: #{inspect(reason)}")
        unchanged(state)
    end
  end

  defp unchanged(state) do
    {:ok, %{last_pushed_commit: Map.get(state, :last_pushed_commit), force_push_halted: false, ingested: []}}
  end

  defp run_with_fetched_head(state, fetched_head) do
    case Map.get(state, :last_pushed_commit) do
      nil ->
        # Bootstrap: first time this bridge has ever looked at the
        # remote (fresh server, or state not yet persisted across a
        # restart). Adopt the fetched head as the new baseline WITHOUT
        # ingesting — there is no known-good prior anchor to diff
        # against, so treating the entirety of remote history as one
        # inbound diff would be a guess, not a merge. The bootstrap
        # doc-anchors (sidecar) already reflect whatever this bridge
        # last exported, so subsequent cycles behave normally.
        {:ok, %{last_pushed_commit: fetched_head, force_push_halted: false, ingested: []}}

      last_pushed ->
        do_ingest(state, last_pushed, fetched_head)
    end
  end

  defp do_ingest(state, last_pushed, fetched_head) do
    repo_dir = state.repo_dir

    cond do
      fetched_head == last_pushed ->
        # ECHO: nothing changed upstream since we last reconciled.
        {:ok, %{last_pushed_commit: last_pushed, force_push_halted: false, ingested: []}}

      true ->
        case Git.ancestor?(repo_dir, last_pushed, fetched_head) do
          {:ok, true} ->
            ingested = ingest_changed_files(state, last_pushed, fetched_head)
            {:ok, %{last_pushed_commit: fetched_head, force_push_halted: false, ingested: ingested}}

          {:ok, false} ->
            PubSub.broadcast_red(
              state.mount_uuid,
              {:git_bridge, :force_push_detected,
               %{last_pushed_commit: last_pushed, fetched_head: fetched_head}}
            )

            {:ok, %{last_pushed_commit: last_pushed, force_push_halted: true, ingested: []}}

          {:error, reason} ->
            Logger.warning(
              "GitBridge.Inbound: ancestry check failed for #{state.mount_uuid}: #{inspect(reason)}"
            )

            {:ok, %{last_pushed_commit: last_pushed, force_push_halted: false, ingested: []}}
        end
    end
  end

  defp ingest_changed_files(state, last_pushed, fetched_head) do
    repo_dir = state.repo_dir

    case Git.diff_name_status(repo_dir, last_pushed, fetched_head) do
      {:ok, rows} ->
        manifest = Sidecar.read_previous_manifest(repo_dir)

        rows
        |> Enum.reject(&sidecar_owned?/1)
        |> Enum.map(fn {status, rel_path} ->
          ingest_one(state, manifest, fetched_head, status, rel_path)
        end)
        |> Enum.reject(&is_nil/1)

      {:error, reason} ->
        Logger.warning("GitBridge.Inbound: diff failed for #{state.mount_uuid}: #{inspect(reason)}")
        []
    end
  end

  defp sidecar_owned?({_status, rel_path}) do
    rel_path == ".gitattributes" or String.starts_with?(rel_path, ".commonplace/")
  end

  defp ingest_one(state, _manifest, _fetched_head, "A", rel_path), do: reject(state, rel_path, :added)
  defp ingest_one(state, _manifest, _fetched_head, "D", rel_path), do: reject(state, rel_path, :deleted)

  defp ingest_one(state, manifest, fetched_head, status, rel_path) when status in ["M"] do
    case Map.get(manifest, rel_path) do
      nil ->
        reject(state, rel_path, :unknown_to_sidecar)

      %{"type" => "text"} = info ->
        ingest_text(state, rel_path, info, fetched_head)

      %{"type" => _other} ->
        reject(state, rel_path, :structured_class)
    end
  end

  # Renames, mode changes, etc. — not v1 scope; conservative reject.
  defp ingest_one(state, _manifest, _fetched_head, _status, rel_path), do: reject(state, rel_path, :unsupported_status)

  defp ingest_text(state, rel_path, %{"uuid" => uuid, "anchor" => anchor_hex}, fetched_head) do
    repo_dir = state.repo_dir
    anchor = Base.decode16!(anchor_hex, case: :lower)

    with {:ok, base_doc} <- DocBuilder.reconstruct_doc_at(state.store, uuid, anchor) |> ok_or(:no_anchor),
         base = ContentType.get_content(base_doc) || "",
         {:ok, theirs} <- Git.show(repo_dir, fetched_head, rel_path),
         {:ok, ours_doc} <- DocBuilder.reconstruct_doc(state.store, uuid) |> ok_or(:no_doc),
         ours = ContentType.get_content(ours_doc) || "" do
      cond do
        theirs == base ->
          nil

        max(byte_size(base), byte_size(theirs)) > max_inbound_bytes(state) ->
          PubSub.broadcast_red(state.mount_uuid, {:git_bridge, :inbound_size_capped, %{rel_path: rel_path, uuid: uuid}})
          marker_path = write_conflict_file(repo_dir, rel_path, fetched_head, theirs)
          %{rel_path: rel_path, uuid: uuid, outcome: :conflict, reason: :too_large, conflict_path: marker_path, conflict_content: theirs}

        ours == base ->
          case mint_edit(state.store, uuid, anchor, base, theirs, bridge_signing_context(state)) do
            {:ok, commit} ->
              %{rel_path: rel_path, uuid: uuid, outcome: :clean, commit_id: commit.id}

            {:error, reason} ->
              Logger.warning("GitBridge.Inbound: mint failed for #{rel_path}: #{inspect(reason)}")
              marker_path = write_conflict_file(repo_dir, rel_path, fetched_head, theirs)
              PubSub.broadcast_red(state.mount_uuid, {:git_bridge, :conflict_preserved, %{rel_path: rel_path, uuid: uuid, reason: :mint_failed}})
              %{rel_path: rel_path, uuid: uuid, outcome: :conflict, reason: :mint_failed, conflict_path: marker_path, conflict_content: theirs}
          end

        true ->
          # Both sides moved since the anchor: CRDT wins, git's edit is
          # preserved alongside (never silently dropped) rather than
          # applied.
          marker_path = write_conflict_file(repo_dir, rel_path, fetched_head, theirs)
          PubSub.broadcast_red(state.mount_uuid, {:git_bridge, :conflict_preserved, %{rel_path: rel_path, uuid: uuid, reason: :both_moved}})
          %{rel_path: rel_path, uuid: uuid, outcome: :conflict, reason: :both_moved, conflict_path: marker_path, conflict_content: theirs}
      end
    else
      {:error, reason} ->
        Logger.warning("GitBridge.Inbound: could not resolve #{rel_path}: #{inspect(reason)}")
        %{rel_path: rel_path, uuid: uuid, outcome: :conflict, reason: reason}
    end
  end

  defp ok_or(:none, tag), do: {:error, tag}
  defp ok_or({:ok, doc}, _tag), do: {:ok, doc}
  defp ok_or(other, _tag), do: other

  defp reject(state, rel_path, reason) do
    PubSub.broadcast_red(state.mount_uuid, {:git_bridge, :conflict_preserved, %{rel_path: rel_path, reason: reason}})
    %{rel_path: rel_path, uuid: nil, outcome: :conflict, reason: reason}
  end

  defp write_conflict_file(repo_dir, rel_path, fetched_head, theirs) do
    shortsha = String.slice(fetched_head, 0, 8)
    marker_rel_path = rel_path <> ".conflict-" <> shortsha
    path = Path.join(repo_dir, marker_rel_path)
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, theirs)
    marker_rel_path
  end

  @doc """
  Re-materialize a conflict marker at `rel_path` under `repo_dir` with
  `content`. Idempotent (plain overwrite). Used by `Server` to survive
  the push-reject worktree reset (`Git.reset_hard/2` discards
  uncommitted/rejected-commit content, including conflict markers —
  they must be written by an in-memory-state source of truth, not
  trusted to persist across a hard reset) so a still-unresolved
  conflict marker keeps riding subsequent export commits until it's
  actually pushed.
  """
  @spec rewrite_conflict_marker(String.t(), String.t(), String.t()) :: :ok
  def rewrite_conflict_marker(repo_dir, rel_path, content) do
    path = Path.join(repo_dir, rel_path)
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, content)
    :ok
  end

  @doc """
  The single seam every G2-minted commit passes through (see moduledoc
  "fourth ingress" note — CX-qat5.3 will gate this with
  `Trust.authorized?(:write)` when it lands; do not scatter
  `CommitStoreClient.create_commit/6` calls elsewhere in this module).

  Reconstructs a REPLICA doc at `anchor_commit_id` under a stable,
  bridge-specific client id (so repeated ingests from this bridge don't
  bloat the state vector — mirrors `Sync.Agent`'s stale-write
  `stable_client_id/1` pattern), applies the whole-content diff from
  `base_text` to `theirs_text`, and persists the resulting update as a
  commit chained off `anchor_commit_id`.
  """
  @spec mint_edit(GenServer.server(), String.t(), binary(), String.t(), String.t(), keyword()) ::
          {:ok, Commonplace.Store.Commit.t()} | {:error, term()}
  def mint_edit(store, doc_uuid, anchor_commit_id, base_text, theirs_text, opts \\ []) do
    with {:ok, anchor_doc} <- DocBuilder.reconstruct_doc_at(store, doc_uuid, anchor_commit_id) |> ok_or(:no_anchor) do
      replica = Yelixer.Doc.new(client_id: stable_client_id(doc_uuid))
      {:ok, replica} = Yelixer.Encoding.apply_update(replica, Yelixer.Encoding.encode_update(anchor_doc))

      replica = Commonplace.Document.Diff.apply_diff(replica, base_text, theirs_text)
      update = Yelixer.Encoding.encode_update(replica)

      metadata = %{kind: :git_bridge_inbound}

      case CommitStoreClient.create_commit(store, doc_uuid, update, anchor_commit_id, metadata, opts) do
        %Commonplace.Store.Commit{} = commit -> {:ok, commit}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # CX-b0ow.2: distinct salt from Sync.Agent's stale-write
  # `stable_client_id/1` (`agent.ex`) — different write path, must not
  # collide client ids with a live editing agent's replica slot.
  defp stable_client_id(uuid) when is_binary(uuid) do
    :erlang.phash2({:git_bridge_inbound, uuid}, 0xFFFF_FFFF)
  end

  defp bridge_signing_context(state) do
    identity_uuid = bridge_identity_uuid(state.mount_uuid)
    secret_store = Map.get(state, :secret_store, Commonplace.Store.SecretStore)

    case AgentKeys.ensure(identity_uuid, secret_store) do
      {:ok, _pub} ->
        case AgentKeys.signing_context_for(identity_uuid, secret_store) do
          {:ok, ctx} -> [signing_context: ctx]
          _ -> []
        end

      _ ->
        []
    end
  end

  @doc "The bridge's persistent signing identity uuid for `mount_uuid` — stable custody slot key."
  @spec bridge_identity_uuid(String.t()) :: String.t()
  def bridge_identity_uuid(mount_uuid), do: "git-bridge:" <> mount_uuid

  defp max_inbound_bytes(state) do
    Map.get(
      state,
      :max_inbound_bytes,
      Application.get_env(:commonplace, :git_bridge_max_inbound_bytes, @default_max_inbound_bytes)
    )
  end
end

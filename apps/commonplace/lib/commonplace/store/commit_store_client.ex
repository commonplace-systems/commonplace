defmodule Commonplace.Store.CommitStoreClient do
  @moduledoc """
  The dispatch seam in front of `CommitStore`: routes each call to either
  a remote `commonplace serve` node or the local GenServer.

  ## Why this layer exists

  `CommitStore` is a singleton GenServer owning a single on-disk CubDB at
  `.commonplace/commits/`, and CubDB opens that directory *exclusively* —
  only one OS process can hold it. So when `commonplace serve` is running
  it owns the database, and a separately-launched CLI or MCP escript
  (a different OS process) **cannot** open its own copy; doing so would
  fail, or worse, fork the `:latest` pointer. Instead those processes
  route their CommitStore calls over BEAM distribution to the serve
  node's GenServer. When no serve is running, the CLI starts its *own*
  local CommitStore and calls it directly. This module hides that fork so
  every call site is written the same way regardless of mode — which is
  why the project rule is "always go through `CommitStoreClient`, never
  `CommitStore` directly."

  ## The routing switch

  Mode is decided per-call by `remote_node/0`, which reads a node-wide
  `:persistent_term` set once at bootstrap (`set_remote_node/1`). It is
  node-wide deliberately: the MCP server spawns helper GenServers (e.g.
  `Presence.Server`) that must see the same routing the escript main
  process configured — see `remote_node/0`.

  ## API shape and gotchas

  Mirrors `CommitStore`'s API so it is a drop-in replacement. Two things
  to know:

    * **`server` normalization.** Callers alias this module as the
      `server` arg; `normalize_server/1` maps `__MODULE__` back to the
      real `CommitStore` for the local branch, and passes anything else
      through unchanged (so tests can inject a custom store instance).
    * **Remote "chained" writes take two round-trips.** The remote side
      exposes only `create_commit` (explicit parent), not the
      auto-parenting `create_chained_commit`. So in remote mode this
      module first calls `{:latest_commit, doc_uuid}` to learn the parent,
      then `create_commit` with it — see `create_chained_commit/5` and
      `create_snapshot_commit/4`. (`opts`, notably `:signing_context`, is
      threaded through that second call so remote-routed signed writes
      don't silently drop their identity — CX-o3r7.)

  Coverage is not total: `snapshot/2` is **local-only** — remote-serve
  dispatch for it is not yet wired (see that function's doc), so callers
  in remote mode must invoke `CommitStore.snapshot/2` on the serve node.
  """

  # CX-3erd: local-mode writes build+sign caller-side.
  #
  # In LOCAL mode, create_commit/6 and create_chained_commit/5 no longer
  # hand the whole build+sign pipeline to CommitStore's serialized
  # handle_call. Instead this module reads :latest directly off
  # CommitStore.db_handle/1 (a plain CubDB point-read, no GenServer
  # call), builds and signs the commit via
  # Commonplace.Store.CommitBuilder.build/6 in the CALLING process, and
  # lands it with CommitStore.put_built_commit/4, a CAS'd verb. A
  # bounded retry loop (@max_chain_attempts) handles the
  # {:error, :parent_moved} case (someone else's write landed first --
  # re-read, rebuild, retry); after exhaustion this module falls back
  # to the legacy fully-serialized CommitStore.create_commit/6 /
  # create_chained_commit/5 verbs so a writer always eventually makes
  # progress even under sustained contention. See CommitStore's
  # moduledoc, "Atomicity of create_chained_commit (CX-l7j)", for why
  # the caller-side read is safe (CubDB's MVCC snapshots) and why
  # correctness rests on the CAS, not the read.
  #
  # REMOTE mode is completely unaffected -- remote callers still route
  # through the legacy GenServer.call shapes below, since there's no
  # local CubDB handle to read :latest from without a round-trip anyway.

  alias Commonplace.Store.{CommitStore, CommitBuilder, Commit}

  # Bounded optimistic-CAS retry count for the caller-side hoisted write
  # path, before falling back to the legacy serialized verb. Kept small
  # -- a handful of retries covers ordinary contention; sustained
  # contention past this is exactly what the fallback is for.
  @max_chain_attempts 5

  defp normalize_server(__MODULE__), do: CommitStore
  defp normalize_server(server), do: server

  def create_commit(server \\ CommitStore, doc_uuid, update, parent_id, metadata \\ %{}, opts \\ []) do
    case remote_node() do
      {:ok, node} ->
        # CX-88mw: opts (notably :signing_context) ride along on the
        # remote call too — same gap-closure as create_chained_commit/5.
        GenServer.call(
          {CommitStore, node},
          {:create_commit, doc_uuid, update, parent_id, metadata, opts}
        )

      :local ->
        local_server = normalize_server(server)

        caller_side_write(
          local_server,
          doc_uuid,
          update,
          metadata,
          opts,
          fn _observed_latest_id -> parent_id end,
          fn -> CommitStore.create_commit(local_server, doc_uuid, update, parent_id, metadata, opts) end
        )
    end
  end

  def create_chained_commit(server \\ CommitStore, doc_uuid, update, metadata \\ %{}, opts \\ []) do
    case remote_node() do
      {:ok, node} ->
        parent_id = case GenServer.call({CommitStore, node}, {:latest_commit, doc_uuid}) do
          {:ok, commit} -> commit.id
          :none -> nil
        end
        # CX-o3r7: opts (notably :signing_context) carry through to the
        # remote create_commit call so signing-context-tagged writes don't
        # silently drop the context just because the local node is in
        # remote-routing mode. The local branch already had this via
        # CommitStore.create_chained_commit/5; remote was the gap.
        GenServer.call(
          {CommitStore, node},
          {:create_commit, doc_uuid, update, parent_id, metadata, opts}
        )

      :local ->
        local_server = normalize_server(server)

        caller_side_write(
          local_server,
          doc_uuid,
          update,
          metadata,
          opts,
          fn observed_latest_id -> observed_latest_id end,
          fn -> CommitStore.create_chained_commit(local_server, doc_uuid, update, metadata, opts) end
        )
    end
  end

  # CX-3erd: bounded optimistic-CAS write loop, LOCAL mode only.
  #
  # `parent_fun.(observed_latest_id)` decides what parent_id to build
  # against — `create_chained_commit` chains to whatever :latest was
  # observed; `create_commit` ignores the observation and always uses
  # its caller-supplied explicit parent_id (the observation is used
  # ONLY as the CAS's `expected_parent_id`, so a race is detected
  # regardless of which parent the caller chose to build against).
  #
  # `legacy_fallback` is the fully-serialized CommitStore verb, invoked
  # only after @max_chain_attempts consecutive CAS losses.
  defp caller_side_write(server, doc_uuid, update, metadata, opts, parent_fun, legacy_fallback) do
    db = CommitStore.db_handle(server)
    attempt_write(db, server, doc_uuid, update, metadata, opts, parent_fun, legacy_fallback, @max_chain_attempts)
  end

  defp attempt_write(_db, _server, _doc_uuid, _update, _metadata, _opts, _parent_fun, legacy_fallback, 0) do
    legacy_fallback.()
  end

  defp attempt_write(db, server, doc_uuid, update, metadata, opts, parent_fun, legacy_fallback, attempts_left) do
    observed_latest_id = CubDB.get(db, {:latest, doc_uuid})
    parent_id = parent_fun.(observed_latest_id)

    built = CommitBuilder.build(db, doc_uuid, update, parent_id, metadata, opts)

    case CommitStore.put_built_commit(server, built.commit, observed_latest_id, built.genesis) do
      {:ok, commit} ->
        commit

      {:error, :parent_moved} ->
        attempt_write(
          db,
          server,
          doc_uuid,
          update,
          metadata,
          opts,
          parent_fun,
          legacy_fallback,
          attempts_left - 1
        )
    end
  end

  @doc """
  Pass-through for `CommitStore.snapshot/2` (CX-u7p / CX-2ok0).

  Forces an umbrella-shaped snapshot commit for `doc_uuid` regardless
  of the chain-length / size threshold. Routed via the local CommitStore
  GenServer; remote-serve dispatch is not yet wired (snapshot construction
  requires a multi-step build that's awkward to round-trip through a
  single GenServer call), so callers in remote mode currently need to
  invoke `CommitStore.snapshot/2` directly on the serve node.
  """
  def snapshot(server \\ CommitStore, doc_uuid) do
    CommitStore.snapshot(normalize_server(server), doc_uuid)
  end

  @doc """
  Pass-through for `CommitStore.create_snapshot_commit/4` (CX-u7p).
  Mirrors the local/remote dispatch pattern used for every other write.
  """
  def create_snapshot_commit(server \\ CommitStore, doc_uuid, update, metadata \\ %{}) do
    metadata = Map.put(metadata, :kind, :snapshot)

    case remote_node() do
      {:ok, node} ->
        parent_id =
          case GenServer.call({CommitStore, node}, {:latest_commit, doc_uuid}) do
            {:ok, commit} -> commit.id
            :none -> nil
          end

        GenServer.call(
          {CommitStore, node},
          {:create_commit, doc_uuid, update, parent_id, metadata}
        )

      :local ->
        CommitStore.create_snapshot_commit(normalize_server(server), doc_uuid, update, metadata)
    end
  end

  def get_commit(server \\ CommitStore, commit_id) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:get_commit, commit_id})

      :local ->
        CommitStore.get_commit(normalize_server(server), commit_id)
    end
  end

  def store_capability(server \\ CommitStore, cap) do
    case remote_node() do
      {:ok, node} -> GenServer.call({CommitStore, node}, {:store_capability, cap})
      :local -> CommitStore.store_capability(normalize_server(server), cap)
    end
  end

  def get_capability(server \\ CommitStore, cid) do
    case remote_node() do
      {:ok, node} -> GenServer.call({CommitStore, node}, {:get_capability, cid})
      :local -> CommitStore.get_capability(normalize_server(server), cid)
    end
  end

  # execute_clean watermark cache (CX-tdkq.27) — node-local; in a clustered
  # setup it lives with the db on the serving node, so route like commit_log.
  def get_execute_clean(server \\ CommitStore, fp, commit_id) do
    case remote_node() do
      {:ok, node} -> GenServer.call({CommitStore, node}, {:get_execute_clean, fp, commit_id})
      :local -> CommitStore.get_execute_clean(normalize_server(server), fp, commit_id)
    end
  end

  def put_execute_clean(server \\ CommitStore, fp, commit_id, bool) do
    case remote_node() do
      {:ok, node} -> GenServer.cast({CommitStore, node}, {:put_execute_clean, fp, commit_id, bool})
      :local -> CommitStore.put_execute_clean(normalize_server(server), fp, commit_id, bool)
    end
  end

  def flush_execute_clean(server \\ CommitStore) do
    case remote_node() do
      {:ok, node} -> GenServer.call({CommitStore, node}, :flush_execute_clean)
      :local -> CommitStore.flush_execute_clean(normalize_server(server))
    end
  end

  def latest_commit(server \\ CommitStore, doc_uuid) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:latest_commit, doc_uuid})

      :local ->
        CommitStore.latest_commit(normalize_server(server), doc_uuid)
    end
  end

  def commit_log(server \\ CommitStore, doc_uuid, opts \\ []) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:commit_log, doc_uuid, opts})

      :local ->
        CommitStore.commit_log(normalize_server(server), doc_uuid, opts)
    end
  end

  def all_doc_uuids(server \\ CommitStore) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, :all_doc_uuids)

      :local ->
        CommitStore.all_doc_uuids(normalize_server(server))
    end
  end

  def is_ancestor?(server \\ CommitStore, ancestor_id, descendant_id) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:is_ancestor, ancestor_id, descendant_id})

      :local ->
        CommitStore.is_ancestor?(normalize_server(server), ancestor_id, descendant_id)
    end
  end

  def set_latest(server \\ CommitStore, doc_uuid, commit_id) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:set_latest, doc_uuid, commit_id})

      :local ->
        CommitStore.set_latest(normalize_server(server), doc_uuid, commit_id)
    end
  end

  def commit_ids_for_doc(server \\ CommitStore, doc_uuid) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:commit_ids_for_doc, doc_uuid})

      :local ->
        CommitStore.commit_ids_for_doc(normalize_server(server), doc_uuid)
    end
  end

  @doc """
  Import a peer's commit (CX-bv3 / CX-ch5). In LOCAL mode, CX-3erd
  hoists the pure id-verification gate (CX-gwz — re-hash the commit
  and compare to its claimed `id`) to THIS edge, so a tampered commit
  is rejected without ever reaching the server's mailbox. The same
  `[:commonplace, :commit, :rejected, :id_mismatch]` telemetry the
  server emits for this case is duplicated here so rejects observed
  at the client edge stay observable exactly like server-side ones.

  Trust / namespace / code-doc gates are NOT duplicated here — they
  stay server-side (`CommitStore.import_commit/3` still runs
  `Commit.verify_id/1` too, for remote callers and as defense in
  depth; see that function's `handle_call`).
  """
  def import_commit(server \\ CommitStore, commit, opts \\ []) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:import_commit, commit, opts})

      :local ->
        case Commit.verify_id(commit) do
          :ok ->
            CommitStore.import_commit(normalize_server(server), commit, opts)

          {:error, {:id_mismatch, computed, claimed}} = error ->
            :telemetry.execute(
              [:commonplace, :commit, :rejected, :id_mismatch],
              %{system_time: System.system_time()},
              %{claimed_id: claimed, computed_id: computed, doc_uuid: commit.doc_uuid}
            )

            error
        end
    end
  end

  def find_common_ancestor(server \\ CommitStore, uuid_a, uuid_b) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:find_common_ancestor, uuid_a, uuid_b})

      :local ->
        CommitStore.find_common_ancestor(normalize_server(server), uuid_a, uuid_b)
    end
  end

  def set_merge_point(server \\ CommitStore, target_uuid, source_uuid, commit_id) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:set_merge_point, target_uuid, source_uuid, commit_id})

      :local ->
        CommitStore.set_merge_point(normalize_server(server), target_uuid, source_uuid, commit_id)
    end
  end

  def get_merge_point(server \\ CommitStore, target_uuid, source_uuid) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:get_merge_point, target_uuid, source_uuid})

      :local ->
        CommitStore.get_merge_point(normalize_server(server), target_uuid, source_uuid)
    end
  end

  def set_last_merge_commit(server \\ CommitStore, target_uuid, source_uuid, commit_id) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:set_last_merge_commit, target_uuid, source_uuid, commit_id})

      :local ->
        CommitStore.set_last_merge_commit(normalize_server(server), target_uuid, source_uuid, commit_id)
    end
  end

  def get_latest_merge_head(server \\ CommitStore, target_uuid) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:get_latest_merge_head, target_uuid})

      :local ->
        CommitStore.get_latest_merge_head(normalize_server(server), target_uuid)
    end
  end

  @doc """
  Check if we're connected to a remote serve node.
  Returns `{:ok, node}` if connected, `:local` otherwise.

  Routing is stored in `:persistent_term` so it is visible from every
  process on the BEAM (not just the one that called `set_remote_node/1`).
  This matters for the MCP server, which spawns helper GenServers
  (e.g. `Presence.Server`) that need to see the same routing the
  escript main process configured.
  """
  def remote_node do
    case :persistent_term.get(:commonplace_remote_node, nil) do
      nil -> :local
      node -> {:ok, node}
    end
  end

  @doc """
  Set the remote node node-wide. Called by CLI.ensure_started and the
  MCP escript bootstrap when they connect to a running serve.
  """
  def set_remote_node(node) do
    :persistent_term.put(:commonplace_remote_node, node)
  end

  @doc """
  Clear the remote node setting node-wide. Primarily for tests; in
  production the escript exits and persistent_term goes away with the
  BEAM.
  """
  def clear_remote_node do
    _ = :persistent_term.erase(:commonplace_remote_node)
    :ok
  end
end

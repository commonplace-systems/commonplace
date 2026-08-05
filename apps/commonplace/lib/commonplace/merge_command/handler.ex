defmodule Commonplace.MergeCommand.Handler do
  @moduledoc """
  Singleton GenServer handling magenta merge commands (CX-8qzi + CX-3hvu).

  Subscribes to the "merge" verb sentinel so one process sees every
  `commands/{path}/merge` command sent on the node — no per-path
  supervisor tree (β topology, per plan-bot msg 2315). Per-path
  addressability is preserved at the topic namespace: callers still
  publish to `magenta:commands/{path}/merge`, and replies fan back to
  that same per-path topic so subscribers (clients, red-log onramps)
  stay anchored to what they asked about.

  Incoming request shape (CX-3hvu):
  - type: `"merge"`
  - payload: `%{"other_ref" => <lowercase-hex>, "strategy" => "translate" | "merge_snapshot"}`

  `other_ref` is hex-encoded so the request payload round-trips through
  JSON — the lazy red-log onramp persists every magenta message it
  hears (including requests), and `Jason.encode!` rejects raw non-UTF8
  binaries.

  `l_id` is resolved from `{path}`'s current HEAD by walking the
  workspace root schema — the topic name is the authoritative address
  for which doc is being merged. Handlers configured without a
  `root_uuid` (or commands whose path doesn't resolve) yield
  `merge_failed` with `:no_root_uuid` / `:path_unresolved`.

  Outgoing reply shape (published back on the same per-path topic):
  - type: `"merge_completed"` | `"merge_failed"` (literal types per
    jes answer B — not generic `Events.run` verb envelopes)
  - payload success: `%{"commit_id" => hex, "path" => path}`
  - payload failure: `%{"reason" => inspected, "path" => path}`

  `commit_id` is lowercase-hex encoded so the reply payload round-trips
  through JSON — the onramp persists events via `Jason.encode!`, which
  rejects non-UTF8 binaries.

  ## Deterministic, idempotent merges (CX-1mml)

  Two peers can invoke `merge` on the same sibling pair concurrently,
  each seeing it locally as `{latest, other_ref}` in the opposite order.
  Before merging, the handler canonicalizes the pair by CID
  (`Merger.canonical_pair/2`) so both feed the merge in the same order
  and produce a *byte-identical* commit. Net effect: concurrent merges
  of the same pair converge instead of forking the DAG.

  ## Landing the canonical commit (CX-xxav)

  Canonicalization makes the merge *symmetric* (both peers compute the
  same commit) but the merge engines are *asymmetric*: the commit lands
  in canonical-L's namespace with `parent_id == L` and
  `merge_parents == [R]`. So on the peer whose local `:latest` sorts
  SECOND, the canonical commit is a child of the sibling, not of the
  local head — a legitimate, dominating new head, but not a linear
  fast-forward.

  `persist_commit/3` accepts BOTH shapes — a linear fast-forward and a
  dominating non-linear merge — and lands them through ONE verb:
  `CommitStore.put_built_commit/4`, node-signing the commit first
  (that verb does not sign, unlike `write_prebuilt_commit_cas/2`).
  Its CAS compares `:latest` to an independently supplied
  `expected_parent_id`, so passing the head we actually observed covers
  both cases naturally: in the linear case that value simply *is*
  `commit.parent_id`. Advancing `:latest` to a dominating merge loses
  nothing — the local head is in the merge's ancestral closure by
  construction, the same rule `Commonplace.Sync.MergeAdopter` applies to
  *imported* merges. If the observed head is neither the parent nor a
  merge parent, the merge does not descend from the local head at all:
  reply `merge_failed`, there is no id worth advertising.

  ### Why one verb, not two (CX-xxav)

  The obvious implementation is a two-arm split — `write_prebuilt_commit_cas/2`
  for the linear case, `put_built_commit/4` for the other — and it is
  wrong, because those two verbs are gated differently:
  `put_built_commit/4` runs the local write gate (`:local_write_gate`)
  and `write_prebuilt_commit_cas/2` does not. Under `:enforce` that
  split exempts the linear arm from the gate.

  No property of the commit can justify that exemption, by
  construction. Which arm a merge takes is a function of
  `Merger.canonical_pair/2`'s sort order — that is, of *which peer you
  happen to be*, not of any attribute of the commit. The same logical
  merge, byte-identical on both peers, takes the linear arm on one and
  the non-linear arm on the other. Any trust-relevant property one has,
  the other has identically. An exemption keyed to the arm is an
  exemption keyed to a coin flip, and the coin is re-flipped by any
  change that re-rolls commit ids — which is exactly how this bead
  started. Uniform gating is forced; the split is deleted rather than
  documented.

  Consequence worth knowing: merges from this handler no longer pass
  through `write_prebuilt_commit_cas/2`, so they no longer emit its
  `warn_if_non_system_cas` check. That check only fires for NON-system
  kinds and this path mints `kind: :merge` exclusively, so nothing it
  could have caught is reachable here.

  Enforce-mode behaviour is pinned end-to-end by
  `test/commonplace/merge_command/enforce_gate_test.exs`, in both
  directions and both orientations.

  A CAS miss means `:latest` moved under us mid-merge and is reported as
  `merge_failed` with `:merge_head_moved`. It is NEVER swallowed. Prior to CX-xxav `{:error, :parent_moved}` was mapped to
  `{:ok, commit}` and the handler advertised a commit stored nowhere —
  and an advertised `commit_id` does not stay in the reply: the red-log
  onramp above persists every magenta message on this topic, so a
  phantom id is written *durably* into `__merge.log` (or the leaf log),
  a replicated commonplace doc, as a permanent reference to a commit
  that exists in no store. `CommonplaceMcp.CrdtTools` will additionally
  relay a reply payload verbatim to an agent for any interface doc
  configured over this verb. Nothing in-repo reads `payload["commit_id"]`
  programmatically (measured CX-xxav, 2026-08-05).

  ## Red-log onramp (CX-3hvu, CX-nuc2)

  On the first successful merge for a given path, the handler starts a
  `RedLog.start_onramp/3` subscribed to the per-path merge topic. The
  onramp is started BEFORE the reply is published so the first
  `merge_completed` event lands in the log. Subsequent merges on the
  same path reuse the in-memory onramp pid.

  The log's UUID depends on the target doc's shape:

  - Schema target: a `__merge.log` schema entry is lazy-created under
    the target, pointing at a fresh log UUID. Mirrors Bursar's
    `__bursar.log` pattern (`lib/commonplace/green/bursar.ex:497-579`).
    Lets consumers traverse to the log from the tree.

  - Leaf target (CX-nuc2): the log lives at a UUID5-derived address
    (`Commonplace.MergeCommand.MergeLog.log_uuid_for_doc/1`). No schema
    entry is written — adding one would corrupt the leaf's chain.
    Consumers rediscover the log deterministically from the target_uuid.
  """

  use GenServer

  alias Commonplace.Dataflow.{Magenta, RedLog}
  alias Commonplace.MergeCommand.MergeLog
  alias Commonplace.Store.{
    CommitBuilder,
    CommitStore,
    CommitStoreClient,
    Merger,
    MergePolicy
  }
  alias Commonplace.Tree.{DocBuilder, Schema, Walk}
  alias Yelixer.{Doc, Encoding}

  @source "merge_command_handler"
  @merge_log_entry "__merge.log"

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    Magenta.subscribe_to_verb("merge")

    {:ok,
     %{
       store: Keyword.get(opts, :store, CommitStoreClient),
       root_uuid: Keyword.get(opts, :root_uuid),
       onramps: %{}
     }}
  end

  @impl true
  def handle_info({:magenta, topic, %Magenta{type: "merge"} = msg}, state) do
    path = extract_doc_path(topic)

    new_state =
      case handle_merge(path, msg.payload, state) do
        {:ok, target_uuid, reply} when is_binary(target_uuid) ->
          state2 = ensure_onramp(state, path, topic, target_uuid)
          Magenta.send(topic, reply)
          state2

        {:ok, nil, reply} ->
          Magenta.send(topic, reply)
          state

        {:error, reply} ->
          Magenta.send(topic, reply)
          state
      end

    {:noreply, new_state}
  end

  def handle_info({:magenta, _path, %Magenta{}}, state) do
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call({:get_onramp, path}, _from, state) do
    case Map.get(state.onramps, path) do
      pid when is_pid(pid) -> {:reply, {:ok, pid}, state}
      _ -> {:reply, {:error, :not_found}, state}
    end
  end

  defp handle_merge(path, payload, state) do
    with {:ok, target_uuid} <- resolve_path_to_doc(path, state),
         {:ok, latest} <- fetch_latest(state.store, target_uuid),
         {:ok, other_ref} <- fetch_hex_ref(payload, "other_ref"),
         strategy <- parse_strategy(payload["strategy"]),
         # CX-1mml: canonicalize the pair by CID so two peers invoking
         # merge on the same sibling set (but with swapped {latest,
         # other_ref} locally) produce byte-identical commits.
         {l, r} <- Merger.canonical_pair(latest.id, other_ref),
         {:ok, commit} <- MergePolicy.merge(state.store, l, r, strategy: strategy),
         {:ok, persisted} <- persist_commit(state.store, commit, latest.id) do
      reply =
        Magenta.message("merge_completed", @source, %{
          "commit_id" => Base.encode16(persisted.id, case: :lower),
          "path" => path
        })

      {:ok, target_uuid, reply}
    else
      {:error, reason} ->
        {:error,
         Magenta.message("merge_failed", @source, %{
           "reason" => inspect(reason),
           "path" => path
         })}
    end
  end

  defp resolve_path_to_doc(_path, %{root_uuid: nil}), do: {:error, :no_root_uuid}

  defp resolve_path_to_doc(path, %{root_uuid: root, store: store}) do
    case Walk.resolve_path(root, path, schema_loader(store)) do
      {:ok, uuid} -> {:ok, uuid}
      {:error, reason} -> {:error, {:path_unresolved, reason}}
    end
  end

  defp fetch_latest(store, doc_uuid) do
    case CommitStore.latest_commit(store, doc_uuid) do
      {:ok, commit} -> {:ok, commit}
      :none -> {:error, {:no_head, doc_uuid}}
    end
  end

  defp schema_loader(store) do
    fn uuid ->
      case CommitStore.latest_commit(store, uuid) do
        {:ok, commit} ->
          doc = Schema.new_schema()
          {:ok, doc} = Encoding.apply_update(doc, commit.update)
          doc

        :none ->
          Schema.new_schema()
      end
    end
  end

  defp ensure_onramp(state, path, topic, target_uuid) do
    case Map.get(state.onramps, path) do
      pid when is_pid(pid) ->
        state

      _ ->
        log_uuid = resolve_merge_log_uuid(state.store, target_uuid)
        {:ok, pid} = RedLog.start_onramp(log_uuid, topic, state.store)
        %{state | onramps: Map.put(state.onramps, path, pid)}
    end
  end

  # Pick the merge log's UUID based on the target's shape. Schema
  # targets get a traversable `__merge.log` entry; leaf targets get a
  # deterministic UUID5-derived address (CX-nuc2) — writing a schema
  # entry to a leaf would corrupt its chain.
  defp resolve_merge_log_uuid(store, target_uuid) do
    if schema_target?(store, target_uuid) do
      ensure_merge_log_entry(store, target_uuid)
    else
      MergeLog.log_uuid_for_doc(target_uuid)
    end
  end

  # A doc is "schema-shaped" iff its reconstructed state carries both
  # the `__schema` and `entries` YMap types that `Schema.new_schema/0`
  # declares. We can't rely on `Schema.version/1` because snapshot
  # compaction round-trips the YMap types but not every scalar value
  # written into them — a schema target post-snapshot typically has
  # `Schema.version(doc) == nil` even though its structure is intact.
  # We also can't rely on a single-commit apply: merge commits' updates
  # don't re-declare type roots, so `Doc.new()+apply_update(merge_commit)`
  # misses the `__schema`/`entries` types. Full-chain replay via
  # `DocBuilder.reconstruct_doc/2` is authoritative.
  defp schema_target?(store, target_uuid) do
    case DocBuilder.reconstruct_doc(store, target_uuid) do
      {:ok, doc} -> Doc.has_type?(doc, "__schema") and Doc.has_type?(doc, "entries")
      _ -> false
    end
  end

  # Lookup or lazy-create the __merge.log schema entry under
  # `target_uuid`. Parallels Bursar's `__bursar.log` pattern. Only safe
  # to call on schema targets — see `schema_target?/2`.
  defp ensure_merge_log_entry(store, target_uuid) do
    schema = load_target_schema(store, target_uuid)

    case Schema.get_entry(schema, @merge_log_entry) do
      {:ok, entry} ->
        entry.node_id

      :error ->
        log_uuid = UUID.uuid4()
        log = RedLog.new(log_uuid, store)
        RedLog.commit(log)

        updated_schema = Schema.add_file(schema, @merge_log_entry, log_uuid)
        CommitStore.create_chained_commit(
          store,
          target_uuid,
          Encoding.encode_update(updated_schema)
        )

        log_uuid
    end
  end

  defp load_target_schema(store, uuid) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end

  # Land the canonical merge commit and advance `:latest` to it. See the
  # moduledoc's "Landing the canonical commit (CX-xxav)" section for why
  # there are two arms and why a CAS miss is never absorbed.
  defp persist_commit(store, commit, observed_head_id) do
    if dominates_observed_head?(commit, observed_head_id) do
      # `put_built_commit/4` does not sign (unlike the prebuilt-CAS
      # verb), so node-sign here. Signing binds over the already-fixed
      # id, so the advertised id is unchanged — and the cross-peer
      # byte-determinism of CX-1mml is unaffected.
      signed = CommitBuilder.maybe_sign_commit(commit)

      store
      |> CommitStore.put_built_commit(signed, observed_head_id)
      |> cas_result(signed)
    else
      {:error, {:merge_does_not_dominate_head, commit.doc_uuid, observed_head_id}}
    end
  end

  # The observed head is in the merge's immediate ancestry — as its
  # parent (a linear fast-forward) or as a merge parent (dominating but
  # non-linear). Both are safe head advances and both take the same
  # gated verb; see the moduledoc's "Why one verb, not two".
  defp dominates_observed_head?(commit, observed_head_id) do
    commit.parent_id == observed_head_id or observed_head_id in merge_parents(commit)
  end

  defp cas_result({:ok, stored}, _commit), do: {:ok, stored}

  defp cas_result({:error, :parent_moved}, commit),
    do: {:error, {:merge_head_moved, commit.doc_uuid}}

  defp cas_result(other, _commit), do: other

  defp merge_parents(%{merge_parents: parents}) when is_list(parents), do: parents
  defp merge_parents(_), do: []

  defp extract_doc_path(topic) do
    parts = String.split(topic, "/")

    parts
    |> strip_prefix("commands")
    |> strip_suffix("merge")
    |> Enum.join("/")
  end

  defp strip_prefix(["commands" | rest], "commands"), do: rest
  defp strip_prefix(parts, _), do: parts

  defp strip_suffix(parts, suffix) do
    case List.last(parts) do
      ^suffix -> Enum.drop(parts, -1)
      _ -> parts
    end
  end

  defp fetch_hex_ref(payload, key) do
    case Map.get(payload, key) do
      ref when is_binary(ref) and byte_size(ref) > 0 ->
        case Base.decode16(ref, case: :lower) do
          {:ok, bytes} -> {:ok, bytes}
          :error -> {:error, {:invalid_hex_ref, key}}
        end

      _ ->
        {:error, {:missing_ref, key}}
    end
  end

  defp parse_strategy("translate"), do: :translate
  defp parse_strategy("merge_snapshot"), do: :merge_snapshot
  defp parse_strategy(:translate), do: :translate
  defp parse_strategy(:merge_snapshot), do: :merge_snapshot
  defp parse_strategy(_), do: :translate
end

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
  and produce a *byte-identical* commit. Persisting is a CAS that treats
  `:parent_moved` as success, so the second peer's identical commit is a
  no-op rather than a conflict. Net effect: concurrent merges of the
  same pair converge instead of forking the DAG.

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
  alias Commonplace.Store.{CommitStore, CommitStoreClient, Merger, MergePolicy}
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
         {:ok, persisted} <- persist_commit(state.store, commit) do
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

  defp persist_commit(store, commit) do
    case CommitStore.write_prebuilt_commit_cas(store, commit) do
      :ok -> {:ok, commit}
      {:ok, _} -> {:ok, commit}
      {:error, :parent_moved} -> {:ok, commit}
      other -> other
    end
  end

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

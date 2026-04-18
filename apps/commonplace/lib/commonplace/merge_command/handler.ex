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
  - payload: `%{"other_ref" => <hex>, "strategy" => "translate" | "merge_snapshot"}`

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

  ## Red-log onramp (CX-3hvu)

  On the first successful merge for a given path, the handler
  lazy-creates a `__merge.log` schema entry under the target doc
  (mirrors Bursar's `__bursar.log` pattern at
  `lib/commonplace/green/bursar.ex:497-579`) and starts a
  `RedLog.start_onramp/3` for that log, subscribed to the per-path
  merge topic. The onramp is started BEFORE the reply is published so
  the first `merge_completed` event lands in the log. Subsequent
  merges on the same path reuse the in-memory onramp pid. Scope is
  schema-target merges — leaf-doc merges short-circuit with
  `:not_a_schema` until CX-nuc2 lands a design.
  """

  use GenServer

  alias Commonplace.Dataflow.{Magenta, RedLog}
  alias Commonplace.Store.{CommitStore, CommitStoreClient, MergePolicy}
  alias Commonplace.Tree.{Schema, Walk}
  alias Yelixer.Encoding

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
         {:ok, other_ref} <- fetch_ref(payload, "other_ref"),
         strategy <- parse_strategy(payload["strategy"]),
         {:ok, commit} <- MergePolicy.merge(state.store, latest.id, other_ref, strategy: strategy),
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
        log_uuid = ensure_merge_log_entry(state.store, target_uuid)
        {:ok, pid} = RedLog.start_onramp(log_uuid, topic, state.store)
        %{state | onramps: Map.put(state.onramps, path, pid)}
    end
  end

  # Lookup or lazy-create the __merge.log schema entry under
  # `target_uuid`. Parallels Bursar's `__bursar.log` pattern.
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

  defp fetch_ref(payload, key) do
    case Map.get(payload, key) do
      ref when is_binary(ref) and byte_size(ref) > 0 -> {:ok, ref}
      _ -> {:error, {:missing_ref, key}}
    end
  end

  defp parse_strategy("translate"), do: :translate
  defp parse_strategy("merge_snapshot"), do: :merge_snapshot
  defp parse_strategy(:translate), do: :translate
  defp parse_strategy(:merge_snapshot), do: :merge_snapshot
  defp parse_strategy(_), do: :translate
end

defmodule Commonplace.Bd.Frontier.Server do
  @moduledoc """
  Reactive maintainer for the `needs`-based ready/blocked frontier —
  Bd P2 Slice S2.

  Not a generic standing-query engine — deliberately instance-first,
  one concrete process per root, hardcoded to `Commonplace.Bd.Frontier`'s
  query definition (`scope: "/bd/issues/**"`, `edge_field: :needs`,
  `satisfied_statuses: ["closed", "wontfix"]` — see that module).
  Kept as plain data/module attrs there so a future generic engine
  could read the query definition off it; this process is just ONE
  concrete instantiation of it.

  Startable on demand (`start_link/1` or `start_supervised!/1` in
  tests) — deliberately NOT added to any application supervision
  tree by this slice.

  ## What it maintains

  On init, and again on every relevant commit:

    * runs `Frontier.compute/2` from scratch (never trusts its own
      previous state — the walk-oracle equivalence pin in
      `frontier_server_test.exs` checks this against a truly fresh
      walk every time),
    * diffs the new ready set against the previous one and appends a
      `%{"ready_added" => [...], "ready_removed" => [...], "at" => iso}`
      delta to the red log when the sets differ,
    * appends a `%{"alarm" => "dependency-hell", "components" => [...],
      "at" => iso}` event when `Frontier.stranded_components/2` is
      non-empty,
    * rewrites the `__ready.json` / `__blocked.json` view docs under
      `/bd/`.

  ## Subscriptions

  Subscribes (via `Phoenix.PubSub`, `Commonplace.PubSub`) to:

    * `"commits:<issues_dir_uuid>"` — the `/bd/issues/` schema doc;
      fires when an issue is added or removed (`Workspace`'s
      `add_directory` onto that schema).
    * `"commits:<issue_json_uuid>"` for every issue's own
      `__issue.json` doc — fires on `status`/`needs` field writes
      (`Issue.update/5` → `Schemas.write_text_doc/4`).

  When the issues-dir topic fires, subscriptions are re-synced:
  newly-added issues get subscribed, removed issues get unsubscribed.
  This is the piece the brief flagged as underspecified — see the
  moduledoc note on `resync_subscriptions/3` below.
  """

  use GenServer

  alias Commonplace.Bd.{Frontier, Schemas, Workspace}
  alias Commonplace.Dataflow.RedLog
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  @ready_file "__ready.json"
  @blocked_file "__blocked.json"
  @log_file "__frontier_log"

  @doc """
  `opts` — `:root_uuid` (required), `:store` (default
  `CommitStoreClient`). The ready/blocked view docs and the red log
  doc are resolved (or created, idempotently, if this is the first
  Frontier server for this root) under `/bd/` on init.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Returns `%{ready: uuid, blocked: uuid, log: uuid}` for the maintained docs."
  def view_uuids(pid) do
    GenServer.call(pid, :view_uuids)
  end

  @doc """
  Synchronous no-op — since PubSub delivery is async but a GenServer
  drains its mailbox in FIFO order, a round-trip call only returns
  after every commit message enqueued before it has been fully
  processed. Tests use this instead of a race-prone sleep.
  """
  def sync(pid) do
    GenServer.call(pid, :sync)
  end

  @impl true
  def init(opts) do
    root_uuid = Keyword.fetch!(opts, :root_uuid)
    store = Keyword.get(opts, :store, CommitStoreClient)

    bd_uuid = Workspace.ensure_bd_dir(root_uuid, store)
    issues_dir_uuid = Workspace.issues_dir_uuid(root_uuid, store)

    ready_uuid = ensure_json_file(bd_uuid, store, @ready_file)
    blocked_uuid = ensure_json_file(bd_uuid, store, @blocked_file)
    log_uuid = ensure_log_file(bd_uuid, store, @log_file)

    Phoenix.PubSub.subscribe(Commonplace.PubSub, "commits:#{issues_dir_uuid}")
    subscribed_issue_uuids = subscribe_all_issues(root_uuid, store)

    frontier = Frontier.compute(root_uuid, store)
    write_views(ready_uuid, blocked_uuid, frontier, store)

    state = %{
      root_uuid: root_uuid,
      store: store,
      bd_uuid: bd_uuid,
      issues_dir_uuid: issues_dir_uuid,
      ready_uuid: ready_uuid,
      blocked_uuid: blocked_uuid,
      log_uuid: log_uuid,
      subscribed_issue_uuids: subscribed_issue_uuids,
      prev_ready: frontier.ready
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:view_uuids, _from, state) do
    {:reply, %{ready: state.ready_uuid, blocked: state.blocked_uuid, log: state.log_uuid}, state}
  end

  def handle_call(:sync, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:commit, uuid, _commit_id, _metadata}, state) do
    frontier = Frontier.compute(state.root_uuid, state.store)

    log =
      RedLog.load(state.log_uuid, state.store)
      |> append_ready_delta(state.prev_ready, frontier.ready)
      |> append_stranded_alarm(state.root_uuid, state.store)

    _ = RedLog.commit(log)

    write_views(state.ready_uuid, state.blocked_uuid, frontier, state.store)

    subscribed_issue_uuids =
      if uuid == state.issues_dir_uuid do
        resync_subscriptions(state.root_uuid, state.store, state.subscribed_issue_uuids)
      else
        state.subscribed_issue_uuids
      end

    {:noreply,
     %{state | prev_ready: frontier.ready, subscribed_issue_uuids: subscribed_issue_uuids}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## Private — persistence

  defp ensure_json_file(bd_uuid, store, filename) do
    {:ok, schema} = Schemas.load_dir_schema(bd_uuid, store)

    case Schema.get_entry(schema, filename) do
      {:ok, entry} ->
        entry.node_id

      :error ->
        empty = Jason.encode!(%{"ready" => [], "blocked" => [], "computed_at" => nil})
        uuid = Schemas.create_text_doc(empty, store)
        schema = Schema.add_file(schema, filename, uuid)
        update = Encoding.encode_update(schema)
        CommitStoreClient.create_chained_commit(store, bd_uuid, update)
        uuid
    end
  end

  defp ensure_log_file(bd_uuid, store, filename) do
    {:ok, schema} = Schemas.load_dir_schema(bd_uuid, store)

    case Schema.get_entry(schema, filename) do
      {:ok, entry} ->
        entry.node_id

      :error ->
        uuid = UUID.uuid4()
        log = RedLog.new(uuid, store)
        _ = RedLog.commit(log)
        schema = Schema.add_file(schema, filename, uuid)
        update = Encoding.encode_update(schema)
        CommitStoreClient.create_chained_commit(store, bd_uuid, update)
        uuid
    end
  end

  defp write_views(ready_uuid, blocked_uuid, frontier, store) do
    json =
      Jason.encode!(%{
        "ready" => frontier.ready |> MapSet.to_list() |> Enum.sort(),
        "blocked" => frontier.blocked |> MapSet.to_list() |> Enum.sort(),
        "computed_at" => now_iso8601()
      })

    Schemas.write_text_doc(ready_uuid, json, store)
    Schemas.write_text_doc(blocked_uuid, json, store)
  end

  defp append_ready_delta(log, prev_ready, new_ready) do
    added = MapSet.difference(new_ready, prev_ready)
    removed = MapSet.difference(prev_ready, new_ready)

    if MapSet.size(added) > 0 or MapSet.size(removed) > 0 do
      RedLog.append_raw(log, %{
        "ready_added" => added |> MapSet.to_list() |> Enum.sort(),
        "ready_removed" => removed |> MapSet.to_list() |> Enum.sort(),
        "at" => now_iso8601()
      })
    else
      log
    end
  end

  defp append_stranded_alarm(log, root_uuid, store) do
    case Frontier.stranded_components(root_uuid, store) do
      [] ->
        log

      components ->
        RedLog.append_raw(log, %{
          "alarm" => "dependency-hell",
          "components" => Enum.map(components, &Enum.sort/1),
          "at" => now_iso8601()
        })
    end
  end

  ## Private — subscription bookkeeping

  defp subscribe_all_issues(root_uuid, store) do
    uuids = current_issue_json_uuids(root_uuid, store)
    Enum.each(uuids, &subscribe_issue/1)
    MapSet.new(uuids)
  end

  # Design decision (flagged for review): re-sync is driven entirely by
  # the `/bd/issues/` schema doc's own commit — every `Issue.create/4`
  # and any future issue-deletion path writes that schema (an
  # `add_directory`/`remove_entry` call), so it is the one topic
  # guaranteed to fire exactly when the issue SET changes, independent
  # of which fields on which issue changed. Diffing current vs.
  # previously-subscribed `__issue.json` uuids (rather than diffing
  # issue ids) means a rename/replace of an issue's dir entry under an
  # unchanged id would also be picked up, though that's not a path any
  # current Bd.* module exercises.
  defp resync_subscriptions(root_uuid, store, previously_subscribed) do
    current = root_uuid |> current_issue_json_uuids(store) |> MapSet.new()

    MapSet.difference(current, previously_subscribed) |> Enum.each(&subscribe_issue/1)
    MapSet.difference(previously_subscribed, current) |> Enum.each(&unsubscribe_issue/1)

    current
  end

  defp current_issue_json_uuids(root_uuid, store) do
    Workspace.list_issue_entries(root_uuid, store)
    |> Enum.map(fn entry -> issue_json_uuid(entry.node_id, store) end)
    |> Enum.reject(&is_nil/1)
  end

  defp issue_json_uuid(dir_uuid, store) do
    with {:ok, schema} <- Schemas.load_dir_schema(dir_uuid, store),
         {:ok, entry} <- Schema.get_entry(schema, Schemas.issue_filename()) do
      entry.node_id
    else
      _ -> nil
    end
  end

  defp subscribe_issue(uuid), do: Phoenix.PubSub.subscribe(Commonplace.PubSub, "commits:#{uuid}")
  defp unsubscribe_issue(uuid), do: Phoenix.PubSub.unsubscribe(Commonplace.PubSub, "commits:#{uuid}")

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()
end

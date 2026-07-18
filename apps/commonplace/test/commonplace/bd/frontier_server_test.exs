defmodule Commonplace.Bd.Frontier.ServerTest do
  use ExUnit.Case

  alias Commonplace.Bd.Frontier
  alias Commonplace.Bd.Frontier.Server, as: FrontierServer
  alias Commonplace.Bd.Issue
  alias Commonplace.Dataflow.RedLog
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Commonplace.Document.ContentType
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bd_frontier_srv_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store = :"commit_store_frontier_srv_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    root = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root, update, nil)

    %{store: store, root: root}
  end

  defp needs_ticket(id), do: %{"ticket" => id}

  defp read_json_doc(uuid, store) do
    {:ok, doc} = DocBuilder.reconstruct_doc(store, uuid)
    doc |> ContentType.get_content() |> Jason.decode!()
  end

  defp start_server(root, store) do
    pid = start_supervised!({FrontierServer, root_uuid: root, store: store})
    pid
  end

  test "walk-oracle equivalence: maintained view docs == fresh Frontier.compute after a sequence of status changes",
       ctx do
    {:ok, c, _} = Issue.create(ctx.root, %{title: "C"}, ctx.store)
    {:ok, a, _} = Issue.create(ctx.root, %{title: "A", needs: [needs_ticket(c.id)]}, ctx.store)
    {:ok, b, _} = Issue.create(ctx.root, %{title: "B", needs: [needs_ticket(c.id)]}, ctx.store)

    {:ok, _d, _} =
      Issue.create(ctx.root, %{title: "D", needs: [needs_ticket(a.id), needs_ticket(b.id)]}, ctx.store)

    pid = start_server(ctx.root, ctx.store)
    %{ready: ready_uuid, blocked: blocked_uuid} = FrontierServer.view_uuids(pid)

    assert_view_matches_oracle(pid, ready_uuid, blocked_uuid, ctx)

    {:ok, _} = Issue.update(ctx.root, c.id, %{status: "closed"}, ctx.store)
    FrontierServer.sync(pid)
    assert_view_matches_oracle(pid, ready_uuid, blocked_uuid, ctx)

    {:ok, _} = Issue.update(ctx.root, a.id, %{status: "closed"}, ctx.store)
    FrontierServer.sync(pid)
    assert_view_matches_oracle(pid, ready_uuid, blocked_uuid, ctx)

    {:ok, _} = Issue.update(ctx.root, b.id, %{status: "closed"}, ctx.store)
    FrontierServer.sync(pid)
    assert_view_matches_oracle(pid, ready_uuid, blocked_uuid, ctx)
  end

  defp assert_view_matches_oracle(pid, ready_uuid, blocked_uuid, ctx) do
    FrontierServer.sync(pid)
    oracle = Frontier.compute(ctx.root, ctx.store)

    ready_doc = read_json_doc(ready_uuid, ctx.store)
    blocked_doc = read_json_doc(blocked_uuid, ctx.store)

    assert MapSet.new(ready_doc["ready"]) == oracle.ready
    assert MapSet.new(blocked_doc["blocked"]) == oracle.blocked
  end

  test "closing a prereq that frees a dependent appends a ready_added delta naming it", ctx do
    {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
    {:ok, b, _} = Issue.create(ctx.root, %{title: "B", needs: [needs_ticket(a.id)]}, ctx.store)

    pid = start_server(ctx.root, ctx.store)
    %{log: log_uuid} = FrontierServer.view_uuids(pid)

    {:ok, _} = Issue.update(ctx.root, a.id, %{status: "closed"}, ctx.store)
    FrontierServer.sync(pid)

    log = RedLog.load(log_uuid, ctx.store)
    events = RedLog.read(log)

    assert Enum.any?(events, fn e ->
             is_list(e["ready_added"]) and b.id in e["ready_added"]
           end)
  end

  test "healthy graph emits no dependency-hell alarm", ctx do
    {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
    {:ok, _b, _} = Issue.create(ctx.root, %{title: "B", needs: [needs_ticket(a.id)]}, ctx.store)

    pid = start_server(ctx.root, ctx.store)
    %{log: log_uuid} = FrontierServer.view_uuids(pid)

    {:ok, _} = Issue.update(ctx.root, a.id, %{status: "closed"}, ctx.store)
    FrontierServer.sync(pid)

    log = RedLog.load(log_uuid, ctx.store)
    events = RedLog.read(log)

    refute Enum.any?(events, fn e -> e["alarm"] == "dependency-hell" end)
  end

  test "a stranded component (unresolvable-only prereq) triggers a dependency-hell alarm", ctx do
    {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

    pid = start_server(ctx.root, ctx.store)
    %{log: log_uuid} = FrontierServer.view_uuids(pid)

    {:ok, _x, _} =
      Issue.create(ctx.root, %{title: "X", needs: [needs_ticket("CX-ghost")]}, ctx.store)

    FrontierServer.sync(pid)

    # Nudge a second commit event through the already-existing subscription
    # to make sure re-sync and recompute both ran (issues_dir commit from
    # create already triggers it, but this also exercises the ordinary
    # per-issue path).
    {:ok, _} = Issue.update(ctx.root, a.id, %{title: "A (touched)"}, ctx.store)
    FrontierServer.sync(pid)

    log = RedLog.load(log_uuid, ctx.store)
    events = RedLog.read(log)

    assert Enum.any?(events, fn e -> e["alarm"] == "dependency-hell" end)
  end

  test "re-syncs subscriptions when a new issue is added after startup", ctx do
    {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

    pid = start_server(ctx.root, ctx.store)

    {:ok, b, _} = Issue.create(ctx.root, %{title: "B", needs: [needs_ticket(a.id)]}, ctx.store)
    FrontierServer.sync(pid)

    %{ready: ready_uuid, blocked: blocked_uuid} = FrontierServer.view_uuids(pid)
    blocked_doc = read_json_doc(blocked_uuid, ctx.store)
    assert b.id in blocked_doc["blocked"]

    # Now update B directly (not via the issues_dir topic) — this only
    # works if the server subscribed to B's own __issue.json topic during
    # re-sync after B was created.
    {:ok, _} = Issue.update(ctx.root, a.id, %{status: "closed"}, ctx.store)
    FrontierServer.sync(pid)

    ready_doc = read_json_doc(ready_uuid, ctx.store)
    assert b.id in ready_doc["ready"]
  end
end

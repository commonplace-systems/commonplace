defmodule Commonplace.Bd.Frontier.ServerTest do
  use ExUnit.Case

  alias Commonplace.Bd.Frontier
  alias Commonplace.Bd.Frontier.Server, as: FrontierServer
  alias Commonplace.Bd.Issue
  alias Commonplace.Bd.{Schemas, Workspace}
  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Dataflow.RedLog
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Commonplace.Document.ContentType
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bd_frontier_srv_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store = :"commit_store_frontier_srv_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})

    old_trust = Application.get_env(:commonplace, :trust)
    old_gate = Application.get_env(:commonplace, :local_write_gate)

    permissive!()

    on_exit(fn ->
      restore_env(:trust, old_trust)
      restore_env(:local_write_gate, old_gate)
      File.rm_rf!(dir)
    end)

    {pub, priv} = Signing.generate_keypair()

    signing_context = %SigningContext{
      identity_uuid: UUID.uuid4(),
      private_key: priv,
      public_key: pub
    }

    root = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root, update, nil, %{}, signing_context: signing_context)

    %{store: store, root: root, signing_context: signing_context}
  end

  defp restore_env(key, nil), do: Application.delete_env(:commonplace, key)
  defp restore_env(key, value), do: Application.put_env(:commonplace, key, value)

  defp permissive! do
    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: true,
      trusted_identities: %{}
    })

    Application.put_env(:commonplace, :local_write_gate, :off)
  end

  defp strict!(trusted_contexts) do
    trusted =
      Map.new(trusted_contexts, fn signing_context ->
        {signing_context.identity_uuid, Signing.encode_key(signing_context.public_key)}
      end)

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: trusted
    })

    Application.put_env(:commonplace, :local_write_gate, :enforce)
  end

  defp attach(event, callback) do
    id = "#{inspect(event)}-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(id, event, callback, nil)
    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp precreate_view_docs(ctx) do
    signing_opts = [signing_context: ctx.signing_context]
    bd_uuid = Workspace.ensure_bd_dir(ctx.root, ctx.store, signing_opts)

    for filename <- ["_ready.json", "_blocked.json"] do
      uuid = Schemas.create_text_doc("{}", ctx.store, signing_opts)
      {:ok, schema} = Schemas.load_dir_schema(bd_uuid, ctx.store)
      schema = Schema.add_file(schema, filename, uuid)

      CommitStoreClient.create_chained_commit(
        ctx.store,
        bd_uuid,
        Encoding.encode_update(schema),
        %{},
        signing_opts
      )
    end

    bd_uuid
  end

  defp signer_id(signing_context) do
    Signing.signer_id(signing_context.identity_uuid, signing_context.public_key)
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

  defp start_server(root, store, signing_context) do
    start_supervised!(
      {FrontierServer, root_uuid: root, store: store, signing_context: signing_context}
    )
  end

  test "frontier log creation and reactive commits land fixture-signed under enforce", ctx do
    bd_uuid = precreate_view_docs(ctx)
    strict!([ctx.signing_context])

    pid = start_server(ctx.root, ctx.store, ctx.signing_context)
    %{log: log_uuid} = FrontierServer.view_uuids(pid)

    {:ok, bd_head} = CommitStore.latest_commit(ctx.store, bd_uuid)
    {:ok, schema_after} = Schemas.load_dir_schema(bd_uuid, ctx.store)
    assert {:ok, log_entry} = Schema.get_entry(schema_after, "__frontier_log")
    assert log_entry.node_id == log_uuid

    assert CommitStoreClient.commit_ids_for_doc(ctx.store, log_uuid) |> MapSet.size() > 0,
           "frontier schema entry points at a zero-commit log doc"

    {:ok, log_head} = CommitStore.latest_commit(ctx.store, log_uuid)
    expected_signer = signer_id(ctx.signing_context)

    assert bd_head.signer_id == expected_signer
    assert log_head.signer_id == expected_signer

    before_count = CommitStoreClient.commit_ids_for_doc(ctx.store, log_uuid) |> MapSet.size()
    issues_uuid = Workspace.issues_dir_uuid(ctx.root, ctx.store)
    send(pid, {:commit, issues_uuid, "fixture-commit", %{}})
    assert :ok = FrontierServer.sync(pid)

    assert CommitStoreClient.commit_ids_for_doc(ctx.store, log_uuid) |> MapSet.size() ==
             before_count + 1

    {:ok, reactive_head} = CommitStore.latest_commit(ctx.store, log_uuid)
    assert reactive_head.signer_id == expected_signer
  end

  test "a refused log-doc creation leaves no schema entry and the server keeps processing", ctx do
    bd_uuid = precreate_view_docs(ctx)
    strict!([])
    test_pid = self()

    attach([:commonplace, :bd, :frontier, :red_log_create_failed], fn event,
                                                                      _measurements,
                                                                      metadata,
                                                                      _config ->
      send(test_pid, {:frontier_telemetry, event, metadata})
    end)

    pid = start_server(ctx.root, ctx.store, nil)

    assert_receive {:frontier_telemetry, [:commonplace, :bd, :frontier, :red_log_create_failed],
                    metadata}

    assert match?({:trust_rejected, _}, metadata.reason)

    assert CommitStoreClient.commit_ids_for_doc(ctx.store, metadata.log_uuid) |> MapSet.size() ==
             0

    {:ok, schema_after} = Schemas.load_dir_schema(bd_uuid, ctx.store)

    assert :error == Schema.get_entry(schema_after, "__frontier_log"),
           "refused log creation left a schema entry pointing at a zero-commit doc"

    assert Process.alive?(pid)
    send(pid, :still_processing)
    assert :ok = FrontierServer.sync(pid)
    assert Process.alive?(pid)
  end

  test "a refused reactive log write is observable and does not stop the server", ctx do
    precreate_view_docs(ctx)
    strict!([ctx.signing_context])

    pid = start_server(ctx.root, ctx.store, ctx.signing_context)
    %{log: log_uuid} = FrontierServer.view_uuids(pid)
    before_count = CommitStoreClient.commit_ids_for_doc(ctx.store, log_uuid) |> MapSet.size()

    strict!([])
    test_pid = self()

    attach([:commonplace, :bd, :frontier, :red_log_write_failed], fn event,
                                                                     _measurements,
                                                                     metadata,
                                                                     _config ->
      send(test_pid, {:frontier_telemetry, event, metadata})
    end)

    issues_uuid = Workspace.issues_dir_uuid(ctx.root, ctx.store)
    send(pid, {:commit, issues_uuid, "refused-commit", %{}})
    assert :ok = FrontierServer.sync(pid)

    assert_receive {:frontier_telemetry, [:commonplace, :bd, :frontier, :red_log_write_failed],
                    metadata}

    assert match?({:trust_rejected, _}, metadata.reason)

    assert CommitStoreClient.commit_ids_for_doc(ctx.store, log_uuid) |> MapSet.size() ==
             before_count

    assert Process.alive?(pid)
    send(pid, :still_processing)
    assert :ok = FrontierServer.sync(pid)
    assert Process.alive?(pid)
  end

  test "walk-oracle equivalence: maintained view docs == fresh Frontier.compute after a sequence of status changes",
       ctx do
    {:ok, c, _} = Issue.create(ctx.root, %{title: "C"}, ctx.store)
    {:ok, a, _} = Issue.create(ctx.root, %{title: "A", needs: [needs_ticket(c.id)]}, ctx.store)
    {:ok, b, _} = Issue.create(ctx.root, %{title: "B", needs: [needs_ticket(c.id)]}, ctx.store)

    {:ok, _d, _} =
      Issue.create(
        ctx.root,
        %{title: "D", needs: [needs_ticket(a.id), needs_ticket(b.id)]},
        ctx.store
      )

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

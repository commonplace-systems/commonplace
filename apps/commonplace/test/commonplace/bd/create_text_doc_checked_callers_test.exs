defmodule Commonplace.Bd.CreateTextDocCheckedCallersTest do
  use ExUnit.Case, async: false

  alias Commonplace.Bd.Frontier.Server, as: FrontierServer
  alias Commonplace.Bd.{Issue, IssueDocIndex, Label, Schemas, Workspace}
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    old_trust = Application.get_env(:commonplace, :trust)
    old_gate = Application.get_env(:commonplace, :local_write_gate)

    permit_unsigned_writes!()

    dir =
      Path.join(
        System.tmp_dir!(),
        "cp_checked_callers_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    store = :"checked_callers_#{System.unique_integer([:positive])}"
    start_supervised!({CommitStore, data_dir: dir, name: store})

    root = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    _commit = CommitStore.create_commit(store, root, update, nil)

    bd_uuid = Workspace.ensure_bd_dir(root, store)
    issues_uuid = Workspace.issues_dir_uuid(root, store)

    on_exit(fn ->
      restore_env(:trust, old_trust)
      restore_env(:local_write_gate, old_gate)
      File.rm_rf!(dir)
    end)

    %{store: store, root: root, bd_uuid: bd_uuid, issues_uuid: issues_uuid}
  end

  test "issue metadata document denial is reported before any schema link lands", ctx do
    issue = Issue.build_with_id("checked-row-1", %{title: "denied issue metadata"})
    docs_before = CommitStoreClient.all_doc_uuids(ctx.store)
    index_before = IssueDocIndex.entries(ctx.store)

    assert MapSet.size(docs_before) > 0
    deny_after_landed_writes!(0)

    reply = Issue.create_with_id(ctx.root, issue, "body", ctx.store)
    assert_receive {:denied_doc_uuid, denied_doc_uuid}
    docs_after = CommitStoreClient.all_doc_uuids(ctx.store)
    index_after = IssueDocIndex.entries(ctx.store)
    linked? = registered_issue_ids(ctx) |> MapSet.member?(issue.id)

    assert reply == {:error, {:trust_rejected, :unsigned}}
    refute MapSet.member?(docs_after, denied_doc_uuid)
    assert docs_after == docs_before
    assert index_after == index_before
    refute linked?
  end

  test "permitted issue metadata document lands with its schema entry", ctx do
    issue = Issue.build_with_id("checked-row-1-control", %{title: "permitted metadata"})

    assert {:ok, ^issue, dir_uuid} = Issue.create_with_id(ctx.root, issue, "body", ctx.store)
    assert {:ok, schema} = Schemas.load_dir_schema(dir_uuid, ctx.store)
    assert {:ok, entry} = Schema.get_entry(schema, Schemas.issue_filename())
    assert match?({:ok, _commit}, CommitStoreClient.latest_commit(ctx.store, entry.node_id))
    assert MapSet.member?(IssueDocIndex.entries(ctx.store), entry.node_id)
  end

  test "description document denial is reported before the issue directory lands", ctx do
    issue = Issue.build_with_id("checked-row-2", %{title: "denied description"})
    docs_before = CommitStoreClient.all_doc_uuids(ctx.store)
    index_before = IssueDocIndex.entries(ctx.store)

    assert MapSet.size(docs_before) > 0
    deny_after_landed_writes!(1)

    reply = Issue.create_with_id(ctx.root, issue, "body", ctx.store)
    assert_receive {:denied_doc_uuid, denied_doc_uuid}
    docs_after = CommitStoreClient.all_doc_uuids(ctx.store)
    index_after = IssueDocIndex.entries(ctx.store)

    assert reply == {:error, {:trust_rejected, :unsigned}}
    refute MapSet.member?(docs_after, denied_doc_uuid)
    assert MapSet.size(MapSet.difference(docs_after, docs_before)) == 1
    assert MapSet.size(MapSet.difference(index_after, index_before)) == 1
    refute MapSet.member?(registered_issue_ids(ctx), issue.id)
  end

  test "permitted description document lands with its schema entry", ctx do
    issue = Issue.build_with_id("checked-row-2-control", %{title: "permitted description"})

    assert {:ok, ^issue, dir_uuid} = Issue.create_with_id(ctx.root, issue, "body", ctx.store)
    assert {:ok, schema} = Schemas.load_dir_schema(dir_uuid, ctx.store)
    assert {:ok, entry} = Schema.get_entry(schema, Schemas.description_filename())
    assert match?({:ok, _commit}, CommitStoreClient.latest_commit(ctx.store, entry.node_id))
  end

  test "frontier view document denial stops server initialization with the named error", ctx do
    deny_after_landed_writes!(0)
    old_trap_exit = Process.flag(:trap_exit, true)

    result = FrontierServer.start_link(root_uuid: ctx.root, store: ctx.store)
    Process.flag(:trap_exit, old_trap_exit)

    assert result == {:error, {:trust_rejected, :unsigned}}
    assert_receive {:denied_doc_uuid, denied_doc_uuid}
    assert CommitStoreClient.latest_commit(ctx.store, denied_doc_uuid) == :none
    assert {:ok, schema} = Schemas.load_dir_schema(ctx.bd_uuid, ctx.store)
    assert Schema.get_entry(schema, "_ready.json") == :error
  end

  test "permitted frontier view document lands with its schema entry", ctx do
    pid = start_supervised!({FrontierServer, root_uuid: ctx.root, store: ctx.store})
    %{ready: ready_uuid} = FrontierServer.view_uuids(pid)

    assert match?({:ok, _commit}, CommitStoreClient.latest_commit(ctx.store, ready_uuid))
    assert {:ok, schema} = Schemas.load_dir_schema(ctx.bd_uuid, ctx.store)
    assert {:ok, entry} = Schema.get_entry(schema, "_ready.json")
    assert entry.node_id == ready_uuid
  end

  test "directory metadata document denial is returned by create_dir_with_meta", ctx do
    deny_after_landed_writes!(0)

    assert {:error, {:trust_rejected, :unsigned}} =
             Schemas.create_dir_with_meta("meta.json", "{}", ctx.store)

    assert_receive {:denied_doc_uuid, denied_doc_uuid}
    assert CommitStoreClient.latest_commit(ctx.store, denied_doc_uuid) == :none
  end

  test "permitted directory metadata document lands with its schema entry", ctx do
    dir_uuid = Schemas.create_dir_with_meta("meta.json", "{}", ctx.store)

    assert is_binary(dir_uuid)
    assert {:ok, schema} = Schemas.load_dir_schema(dir_uuid, ctx.store)
    assert {:ok, entry} = Schema.get_entry(schema, "meta.json")
    assert match?({:ok, _commit}, CommitStoreClient.latest_commit(ctx.store, entry.node_id))
  end

  test "label metadata document denial is returned before the label directory lands", ctx do
    deny_after_landed_writes!(0)

    assert {:error, {:trust_rejected, :unsigned}} =
             Label.create(ctx.root, "checked-row-5", %{color: "red"}, ctx.store)

    assert_receive {:denied_doc_uuid, denied_doc_uuid}
    assert CommitStoreClient.latest_commit(ctx.store, denied_doc_uuid) == :none
    assert Workspace.label_dir_uuid(ctx.root, "checked-row-5", ctx.store) == :error
  end

  test "permitted label metadata document lands with its schema entry", ctx do
    assert {:ok, label, dir_uuid} =
             Label.create(ctx.root, "checked-row-5-control", %{color: "red"}, ctx.store)

    assert label.name == "checked-row-5-control"
    assert {:ok, schema} = Schemas.load_dir_schema(dir_uuid, ctx.store)
    assert {:ok, entry} = Schema.get_entry(schema, "label.json")
    assert match?({:ok, _commit}, CommitStoreClient.latest_commit(ctx.store, entry.node_id))
  end

  test "document-denied issue create is reported directly and creates no torn row", ctx do
    issue = Issue.build_with_id("checked-detection", %{title: "detected at caller"})
    assert IssueDocIndex.scan(ctx.root, ctx.store) == []
    deny_after_landed_writes!(0)

    assert {:error, {:trust_rejected, :unsigned}} =
             Issue.create_with_id(ctx.root, issue, "body", ctx.store)

    assert_receive {:denied_doc_uuid, denied_doc_uuid}

    torn_create_detected =
      Enum.any?(IssueDocIndex.scan(ctx.root, ctx.store), fn {_id, uuid, _created_at} ->
        uuid == denied_doc_uuid
      end)

    refute torn_create_detected
  end

  defp registered_issue_ids(ctx) do
    assert {:ok, schema} = Schemas.load_dir_schema(ctx.issues_uuid, ctx.store)

    schema
    |> Schema.list_entries()
    |> Enum.filter(&(&1.type == :dir and String.ends_with?(&1.name, ".iss")))
    |> Enum.map(&String.trim_trailing(&1.name, ".iss"))
    |> MapSet.new()
  end

  defp deny_after_landed_writes!(landed_count) do
    test_pid = self()
    success_handler = "deny-after-landed-#{System.unique_integer([:positive])}"
    rejection_handler = "permit-after-denial-#{System.unique_integer([:positive])}"
    counter = start_supervised!({Agent, fn -> 0 end})

    if landed_count == 0, do: deny_unsigned_writes!()

    :ok =
      :telemetry.attach(
        success_handler,
        [:commonplace, :commit_store, :write_cpu],
        fn _event, _measurements, metadata, _config ->
          if metadata.site == :caller do
            count = Agent.get_and_update(counter, fn count -> {count + 1, count + 1} end)
            if count == landed_count, do: deny_unsigned_writes!()
          end
        end,
        nil
      )

    :ok =
      :telemetry.attach(
        rejection_handler,
        [:commonplace, :commit, :rejected, :local_trust],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:denied_doc_uuid, metadata.doc_uuid})
          permit_unsigned_writes!()
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(success_handler)
      :telemetry.detach(rejection_handler)
    end)
  end

  defp permit_unsigned_writes! do
    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: true,
      trusted_identities: %{}
    })

    Application.put_env(:commonplace, :local_write_gate, :off)
  end

  defp deny_unsigned_writes! do
    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{}
    })

    Application.put_env(:commonplace, :local_write_gate, :enforce)
  end

  defp restore_env(key, nil), do: Application.delete_env(:commonplace, key)
  defp restore_env(key, value), do: Application.put_env(:commonplace, key, value)
end

defmodule Commonplace.DeniedWriteReportingTest do
  use ExUnit.Case, async: false

  alias Commonplace.Bd.{Issue, IssueDocIndex, Schemas, Workspace}
  alias Commonplace.CommandRouter
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    old_trust = Application.get_env(:commonplace, :trust)
    old_gate = Application.get_env(:commonplace, :local_write_gate)

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: true,
      trusted_identities: %{}
    })

    Application.put_env(:commonplace, :local_write_gate, :off)

    dir =
      Path.join(
        System.tmp_dir!(),
        "cp_denied_write_reporting_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    store = :"denied_write_reporting_#{System.unique_integer([:positive])}"
    start_supervised!({CommitStore, data_dir: dir, name: store})

    root = UUID.uuid4()

    _commit =
      CommitStore.create_commit(store, root, Encoding.encode_update(Schema.new_schema()), nil)

    bd_uuid = Workspace.ensure_bd_dir(root, store)
    issues_uuid = Workspace.issues_dir_uuid(root, store)

    on_exit(fn ->
      restore_env(:trust, old_trust)
      restore_env(:local_write_gate, old_gate)
      File.rm_rf!(dir)
    end)

    %{store: store, root: root, bd_uuid: bd_uuid, issues_uuid: issues_uuid}
  end

  test "diff write reports an enforced refusal and leaves the head unchanged", ctx do
    uuid = create_text_doc(ctx.store, "before")
    {_pid, router} = start_router(ctx.store)
    head_before = latest_id(ctx.store, uuid)
    enforce_unsigned_denials!()

    reply = CommandRouter.write(router, uuid, "after")
    head_after = latest_id(ctx.store, uuid)

    assert match?({:error, {:trust_rejected, :unsigned}}, reply), """
    observed_reply=#{inspect(reply)}
    write_absent=#{head_after == head_before}
    head_before=#{Base.encode16(head_before, case: :lower)}
    head_after=#{Base.encode16(head_after, case: :lower)}
    """

    assert head_after == head_before
  end

  test "forced clobber reports an enforced refusal and leaves the head unchanged", ctx do
    uuid = create_map_doc(ctx.store)
    {_pid, router} = start_router(ctx.store)
    head_before = latest_id(ctx.store, uuid)
    enforce_unsigned_denials!()

    reply = CommandRouter.write(router, uuid, "forced text", force: true)
    head_after = latest_id(ctx.store, uuid)

    assert match?({:error, {:trust_rejected, :unsigned}}, reply), """
    observed_reply=#{inspect(reply)}
    write_absent=#{head_after == head_before}
    head_before=#{Base.encode16(head_before, case: :lower)}
    head_after=#{Base.encode16(head_after, case: :lower)}
    """

    assert head_after == head_before
  end

  test "branch sync write reports an enforced refusal and leaves the parent head unchanged",
       ctx do
    child_uuid = UUID.uuid4()
    child_update = Encoding.encode_update(Schema.new_schema())
    _commit = CommitStore.create_commit(ctx.store, child_uuid, child_update, nil)

    parent_uuid = UUID.uuid4()
    parent = Schema.new_schema() |> Schema.add_directory("child", child_uuid)

    _commit =
      CommitStore.create_commit(ctx.store, parent_uuid, Encoding.encode_update(parent), nil)

    {_pid, router} = start_router(ctx.store)
    head_before = latest_id(ctx.store, parent_uuid)
    enforce_unsigned_denials!()

    reply = CommandRouter.branch_deactivate(router, parent_uuid, "child")
    head_after = latest_id(ctx.store, parent_uuid)

    assert match?({:error, {:trust_rejected, :unsigned}}, reply), """
    observed_reply=#{inspect(reply)}
    write_absent=#{head_after == head_before}
    head_before=#{Base.encode16(head_before, case: :lower)}
    head_after=#{Base.encode16(head_after, case: :lower)}
    """

    assert head_after == head_before
  end

  test "issue-directory creation reports denial; denied issue-doc index write is also absent",
       ctx do
    issue = Issue.build_with_id("CX-denied-dir", %{title: "denied directory"})
    docs_before = CommitStoreClient.all_doc_uuids(ctx.store)
    index_before = IssueDocIndex.entries(ctx.store)

    assert MapSet.size(docs_before) > 0
    enforce_unsigned_denials!()

    reply = Issue.create_with_id(ctx.root, issue, "body", ctx.store)
    docs_after = CommitStoreClient.all_doc_uuids(ctx.store)
    index_after = IssueDocIndex.entries(ctx.store)
    linked? = registered_issue_ids(ctx) |> MapSet.member?(issue.id)

    assert match?({:error, {:trust_rejected, :unsigned}}, reply), """
    observed_reply=#{inspect(reply)}
    new_docs=#{inspect(MapSet.difference(docs_after, docs_before) |> Enum.sort())}
    issue_doc_index_delta=#{inspect(MapSet.difference(index_after, index_before) |> Enum.sort())}
    linked=#{linked?}
    """

    assert docs_after == docs_before
    assert index_after == index_before
    refute linked?
  end

  test "parent-schema registration reports denial for an existing indexed issue directory", ctx do
    issue = Issue.build_with_id("CX-denied-link", %{title: "denied parent link"})
    tracker = start_supervised!({Agent, fn -> %{count: 0, doc_uuids: []} end})
    handler_id = "deny-parent-link-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:commonplace, :commit_store, :write_cpu],
        fn _event, _measurements, metadata, agent ->
          if metadata.site == :caller do
            count =
              Agent.get_and_update(agent, fn state ->
                next = state.count + 1
                {next, %{state | count: next, doc_uuids: state.doc_uuids ++ [metadata.doc_uuid]}}
              end)

            if count == 4, do: enforce_unsigned_denials!()
          end
        end,
        tracker
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    reply = Issue.create_with_id(ctx.root, issue, "body", ctx.store)
    %{count: landed_count, doc_uuids: landed_docs} = Agent.get(tracker, & &1)
    dir_uuid = Enum.at(landed_docs, 3)

    assert landed_count == 4
    assert is_binary(dir_uuid)
    {:ok, dir_schema} = Schemas.load_dir_schema(dir_uuid, ctx.store)

    # CX-7rjn: `dir_uuid` is selected BY POSITION (`Enum.at(landed_docs, 3)`) from a
    # write sequence whose length is NONDETERMINISTIC -- observed as both 4 and 5 on
    # an unmodified tree. The `is_binary/1` check above is shape, not identity: any
    # uuid satisfies it. So a shifted sequence silently selects the WRONG document.
    # This assertion makes that case fail HERE, naming what was selected, instead of
    # surfacing as a bare MatchError on the next line.
    assert match?({:ok, _}, Schema.get_entry(dir_schema, Schemas.issue_filename())),
           "CX-7rjn: ordinal selection picked a document with no #{Schemas.issue_filename()} " <>
             "entry, so it is not this issue's directory. landed_count=#{landed_count}, " <>
             "dir_uuid=#{inspect(dir_uuid)}. The write-sequence length is nondeterministic, " <>
             "so Enum.at(landed_docs, 3) does not reliably identify the directory doc."

    {:ok, issue_entry} = Schema.get_entry(dir_schema, Schemas.issue_filename())
    issue_doc_uuid = issue_entry.node_id

    document_exists? =
      match?({:ok, _}, CommitStoreClient.latest_commit(ctx.store, issue_doc_uuid))

    indexed? = MapSet.member?(IssueDocIndex.entries(ctx.store), issue_doc_uuid)
    linked? = registered_issue_ids(ctx) |> MapSet.member?(issue.id)
    show_result = Issue.show(ctx.root, issue.id, ctx.store)
    scan_result = IssueDocIndex.scan(ctx.root, ctx.store)

    detected? =
      Enum.any?(scan_result, fn {id, uuid, _created_at} ->
        id == issue.id and uuid == issue_doc_uuid
      end)

    assert match?({:error, {:trust_rejected, :unsigned}}, reply), """
    observed_reply=#{inspect(reply)}
    document_exists=#{document_exists?}
    issue_doc_indexed=#{indexed?}
    parent_schema_linked=#{linked?}
    show_result=#{inspect(show_result)}
    torn_create_detected=#{detected?}
    """

    assert document_exists?
    assert indexed?
    refute linked?
    assert show_result == {:error, :not_found}
    assert detected?
  end

  test "permitted command writes retain their three normal success shapes", ctx do
    text_uuid = create_text_doc(ctx.store, "before")
    map_uuid = create_map_doc(ctx.store)

    child_uuid = UUID.uuid4()

    _commit =
      CommitStore.create_commit(
        ctx.store,
        child_uuid,
        Encoding.encode_update(Schema.new_schema()),
        nil
      )

    parent_uuid = UUID.uuid4()
    parent = Schema.new_schema() |> Schema.add_directory("child", child_uuid)

    _commit =
      CommitStore.create_commit(ctx.store, parent_uuid, Encoding.encode_update(parent), nil)

    {_pid, router} = start_router(ctx.store)

    assert {:ok, %{"forced" => false}} = CommandRouter.write(router, text_uuid, "after")

    assert {:ok, %{"forced" => true}} =
             CommandRouter.write(router, map_uuid, "forced text", force: true)

    assert {:ok, %{"name" => "child", "sync" => false}} =
             CommandRouter.branch_deactivate(router, parent_uuid, "child")
  end

  test "permitted issue creation retains its normal success shape and linkage", ctx do
    issue = Issue.build_with_id("CX-permitted", %{title: "permitted"})

    assert {:ok, ^issue, dir_uuid} =
             Issue.create_with_id(ctx.root, issue, "body", ctx.store)

    assert is_binary(dir_uuid)
    assert MapSet.member?(registered_issue_ids(ctx), issue.id)
    assert {:ok, ^issue} = Issue.show(ctx.root, issue.id, ctx.store)
  end

  defp create_text_doc(store, content) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new() |> ContentType.create(:text, "doc.txt")
    doc = ContentType.insert_text(doc, 0, content)
    _commit = CommitStore.create_commit(store, uuid, Encoding.encode_update(doc), nil)
    uuid
  end

  defp create_map_doc(store) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new() |> ContentType.create(:map, "doc.json")
    _commit = CommitStore.create_commit(store, uuid, Encoding.encode_update(doc), nil)
    uuid
  end

  defp start_router(store) do
    name = :"denied_write_router_#{System.unique_integer([:positive])}"
    pid = start_supervised!({CommandRouter, store: store, name: name})
    {pid, name}
  end

  defp latest_id(store, uuid) do
    {:ok, commit} = CommitStoreClient.latest_commit(store, uuid)
    commit.id
  end

  defp registered_issue_ids(ctx) do
    assert {:ok, schema} = Schemas.load_dir_schema(ctx.issues_uuid, ctx.store)

    schema
    |> Schema.list_entries()
    |> Enum.filter(&(&1.type == :dir and String.ends_with?(&1.name, ".iss")))
    |> Enum.map(&String.trim_trailing(&1.name, ".iss"))
    |> MapSet.new()
  end

  defp enforce_unsigned_denials! do
    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{}
    })

    Application.put_env(:commonplace, :local_write_gate, :enforce)
  end

  defp restore_env(key, nil), do: Application.delete_env(:commonplace, key)
  defp restore_env(key, value), do: Application.put_env(:commonplace, key, value)
end

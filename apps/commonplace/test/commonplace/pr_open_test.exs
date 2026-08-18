defmodule Commonplace.PrOpenTest do
  @moduledoc """
  Tests for the `pr_open` verb (design doc
  docs/plans/2026-07-16-intra-repo-pull-request-design.md §7.0/§7.2,
  commonplace-plan repo).

  Mirrors the fixture pattern `CommonplaceWebWeb.WikiLiveTest` uses for
  any test that needs the default-named `CommitStore` (the store
  `Commonplace.ViewActionDispatch`'s `pr_open` handler talks to via
  `CommitStoreClient`'s default routing) plus a real workspace root —
  `pr_open` reuses `attach_to_root_schema/2`'s move, so it needs the
  same "root pointer file + running default CommitStore" fixture, not
  a custom-named store the dispatcher can't see.
  """
  use ExUnit.Case, async: false

  alias Commonplace.CommandRouter
  alias Commonplace.Crypto.Signing
  alias Commonplace.Crypto.SigningContext
  alias Commonplace.Store.CommitStore
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Commonplace.ViewActionDispatch

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_pr_open_test_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    prior_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(Commonplace.Store.CommitStore, root_uuid, update, nil)

    Commonplace.Test.WorkspaceFixture.complete_workspace!(dir,
      store: Commonplace.Store.CommitStore
    )

    File.write!(Path.join(dir, "root"), root_uuid)

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      restored_data_dir = prior_data_dir || "tmp/test_data"
      Application.put_env(:commonplace, :data_dir, restored_data_dir)
      File.rm_rf!(dir)

      {:ok, restored_pid} =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: restored_data_dir})

      assert Process.alive?(restored_pid)
      assert Process.whereis(Commonplace.Store.CommitStore) == restored_pid

      Commonplace.Test.StoreIdentityAssertion.assert_restored_store!(restored_data_dir)
    end)

    {pub, priv} = Signing.generate_keypair()

    signing_context = %SigningContext{
      identity_uuid: "test-pr-opener",
      private_key: priv,
      public_key: pub
    }

    %{root: root_uuid, signing_context: signing_context}
  end

  defp create_leaf_doc(content) do
    uuid = UUID.uuid4()
    doc = Commonplace.Document.ContentType.create(Yelixer.Doc.new(), :text, "doc.txt")
    doc = Commonplace.Document.ContentType.insert_text(doc, 0, content)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStoreClient.create_commit(CommitStoreClient, uuid, update, nil)
    uuid
  end

  defp attach_at_root(root_uuid, name, uuid) do
    {:ok, root_doc} = DocBuilder.reconstruct_snapshot(CommitStoreClient, root_uuid)
    updated = Schema.add_file(root_doc, name, uuid)
    update = Yelixer.Encoding.encode_update(updated)
    CommitStoreClient.create_chained_commit(CommitStoreClient, root_uuid, update)
  end

  defp pulls_entry(root_uuid, attach_name) do
    {:ok, root_doc} = DocBuilder.reconstruct_snapshot(CommitStoreClient, root_uuid)

    with {:ok, pulls_entry} <- Schema.get_entry(root_doc, "__pulls") do
      {:ok, pulls_doc} = DocBuilder.reconstruct_snapshot(CommitStoreClient, pulls_entry.node_id)
      {pulls_entry.node_id, Schema.get_entry(pulls_doc, attach_name)}
    end
  end

  defp pr_doc_content(pr_uuid) do
    {:ok, doc} = DocBuilder.reconstruct_doc(CommitStoreClient, pr_uuid)
    Commonplace.Document.ContentType.get_content(doc)
  end

  describe "pr_open (§7.2)" do
    test "opens a PR for a valid forked source and attaches it under __pulls/",
         %{root: root_uuid, signing_context: ctx} do
      a_uuid = create_leaf_doc("original content")
      {:ok, b_uuid} = CommandRouter.fork(a_uuid)
      {:ok, _} = CommandRouter.write(b_uuid, "edited in the fork")

      context = %{
        view_uuid: b_uuid,
        args: %{"target" => a_uuid},
        signing_context: ctx,
        source: "test"
      }

      assert {:ok, :tree_mutation, details} = ViewActionDispatch.dispatch("pr_open", context)

      assert details.action == "pr_open"
      assert details.source_uuid == b_uuid
      assert details.target_uuid == a_uuid
      assert is_binary(details.pr_uuid)
      assert details.attached_as == "pr-" <> String.slice(details.pr_uuid, 0, 8)

      {pulls_uuid, entry_result} = pulls_entry(root_uuid, details.attached_as)
      assert is_binary(pulls_uuid)
      assert {:ok, entry} = entry_result
      assert entry.node_id == details.pr_uuid

      content = pr_doc_content(details.pr_uuid)
      expected_principal = Signing.signer_id(ctx.identity_uuid, ctx.public_key)

      assert content =~ ~s(status="open")
      assert content =~ ~s(opened_by="#{expected_principal}")
      assert content =~ ~s(source="#{b_uuid}")
      assert content =~ ~s(target="#{a_uuid}")
      assert content =~ "no preview yet"
    end

    test "target with no common ancestor is refused and attaches nothing",
         %{root: root_uuid, signing_context: ctx} do
      a_uuid = create_leaf_doc("some content")
      {:ok, b_uuid} = CommandRouter.fork(a_uuid)

      unrelated_uuid = create_leaf_doc("totally unrelated doc")

      context = %{
        view_uuid: b_uuid,
        args: %{"target" => unrelated_uuid},
        signing_context: ctx,
        source: "test"
      }

      assert {:error, "pr_open failed: no common ancestor" <> _} =
               ViewActionDispatch.dispatch("pr_open", context)

      {:ok, root_doc} = DocBuilder.reconstruct_snapshot(CommitStoreClient, root_uuid)
      assert Schema.get_entry(root_doc, "__pulls") == :error
    end

    test "registry is idempotent — second pr_open reuses the existing __pulls/ dir",
         %{root: root_uuid, signing_context: ctx} do
      a_uuid = create_leaf_doc("original content")
      {:ok, b1_uuid} = CommandRouter.fork(a_uuid)
      {:ok, b2_uuid} = CommandRouter.fork(a_uuid)

      context1 = %{
        view_uuid: b1_uuid,
        args: %{"target" => a_uuid},
        signing_context: ctx,
        source: "test"
      }

      context2 = %{
        view_uuid: b2_uuid,
        args: %{"target" => a_uuid},
        signing_context: ctx,
        source: "test"
      }

      assert {:ok, :tree_mutation, details1} = ViewActionDispatch.dispatch("pr_open", context1)
      assert {:ok, :tree_mutation, details2} = ViewActionDispatch.dispatch("pr_open", context2)

      refute details1.attached_as == details2.attached_as

      {:ok, root_doc} = DocBuilder.reconstruct_snapshot(CommitStoreClient, root_uuid)
      assert {:ok, pulls_entry1} = Schema.get_entry(root_doc, "__pulls")

      {pulls_uuid2, _} = pulls_entry(root_uuid, details2.attached_as)
      assert pulls_entry1.node_id == pulls_uuid2

      {:ok, pulls_doc} = DocBuilder.reconstruct_snapshot(CommitStoreClient, pulls_entry1.node_id)
      assert {:ok, e1} = Schema.get_entry(pulls_doc, details1.attached_as)
      assert {:ok, e2} = Schema.get_entry(pulls_doc, details2.attached_as)
      assert e1.node_id == details1.pr_uuid
      assert e2.node_id == details2.pr_uuid
    end

    test "path-form target resolves the same as uuid-form",
         %{root: root_uuid, signing_context: ctx} do
      a_uuid = create_leaf_doc("original content")
      {:ok, b_uuid} = CommandRouter.fork(a_uuid)
      attach_at_root(root_uuid, "a-doc", a_uuid)

      context = %{
        view_uuid: b_uuid,
        args: %{"target" => "a-doc"},
        signing_context: ctx,
        source: "test"
      }

      assert {:ok, :tree_mutation, details} = ViewActionDispatch.dispatch("pr_open", context)
      assert details.target_uuid == a_uuid
    end
  end
end

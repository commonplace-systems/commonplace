defmodule Commonplace.PrCommentTest do
  @moduledoc """
  Tests for the `pr_comment` verb (design doc
  docs/plans/2026-07-16-intra-repo-pull-request-design.md §7.4,
  commonplace-plan repo). Any session may comment (attribution is
  honest — an anonymous session's principal shows as the fallback,
  same as `pr_open`'s `opened_by`).

  Fixture pattern mirrors `Commonplace.PrOpenTest`.
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
    dir = Path.join(System.tmp_dir!(), "cp_pr_comment_test_#{:rand.uniform(1_000_000_000)}")
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

      assert CubDB.data_dir(CommitStore.db_handle(CommitStore)) ==
               Path.join(restored_data_dir, "commits")
    end)

    {pub, priv} = Signing.generate_keypair()

    signing_context = %SigningContext{
      identity_uuid: "test-pr-commenter",
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

  defp pr_doc_content(pr_uuid) do
    {:ok, doc} = DocBuilder.reconstruct_doc(CommitStoreClient, pr_uuid)
    Commonplace.Document.ContentType.get_content(doc)
  end

  defp open_pr(ctx, a_uuid, b_uuid) do
    context = %{
      view_uuid: b_uuid,
      args: %{"target" => a_uuid},
      signing_context: ctx,
      source: "test"
    }

    {:ok, :tree_mutation, details} = ViewActionDispatch.dispatch("pr_open", context)
    details.pr_uuid
  end

  defp comment(pr_uuid, ctx, text) do
    context = %{view_uuid: pr_uuid, args: %{"text" => text}, signing_context: ctx, source: "test"}
    ViewActionDispatch.dispatch("pr_comment", context)
  end

  describe "pr_comment (§7.4)" do
    test "appends a comment with principal + text into <section id=\"reviews\">", %{
      signing_context: ctx
    } do
      a_uuid = create_leaf_doc("original content")
      {:ok, b_uuid} = CommandRouter.fork(a_uuid)
      pr_uuid = open_pr(ctx, a_uuid, b_uuid)

      assert {:ok, :tree_mutation, details} = comment(pr_uuid, ctx, "looks good to me")

      expected_principal = Signing.signer_id(ctx.identity_uuid, ctx.public_key)
      assert details.action == "pr_comment"
      assert details.pr_uuid == pr_uuid
      assert details.principal == expected_principal

      content = pr_doc_content(pr_uuid)
      assert content =~ "looks good to me"
      assert content =~ ~s(principal="#{expected_principal}")
      assert content =~ "<comment "
    end

    test "two comments both present (append, not replace)", %{signing_context: ctx} do
      a_uuid = create_leaf_doc("original content")
      {:ok, b_uuid} = CommandRouter.fork(a_uuid)
      pr_uuid = open_pr(ctx, a_uuid, b_uuid)

      assert {:ok, :tree_mutation, _} = comment(pr_uuid, ctx, "first comment")
      assert {:ok, :tree_mutation, _} = comment(pr_uuid, ctx, "second comment")

      content = pr_doc_content(pr_uuid)
      assert content =~ "first comment"
      assert content =~ "second comment"
    end

    test "an anonymous session may comment too — attribution shows the fallback principal" do
      a_uuid = create_leaf_doc("original content")
      {:ok, b_uuid} = CommandRouter.fork(a_uuid)

      # Open under a real identity so the PR exists; comment
      # anonymously (no signing_context at all).
      {pub, priv} = Signing.generate_keypair()

      opener_ctx = %SigningContext{
        identity_uuid: "test-pr-opener2",
        private_key: priv,
        public_key: pub
      }

      pr_uuid = open_pr(opener_ctx, a_uuid, b_uuid)

      context = %{view_uuid: pr_uuid, args: %{"text" => "anon note"}, source: "test"}
      assert {:ok, :tree_mutation, details} = ViewActionDispatch.dispatch("pr_comment", context)
      assert details.principal == "anonymous@local"

      content = pr_doc_content(pr_uuid)
      assert content =~ "anon note"
      assert content =~ ~s(principal="anonymous@local")
    end

    test "missing text arg is refused" do
      a_uuid = create_leaf_doc("original content")
      {:ok, b_uuid} = CommandRouter.fork(a_uuid)

      {pub, priv} = Signing.generate_keypair()

      ctx = %SigningContext{identity_uuid: "test-pr-opener3", private_key: priv, public_key: pub}
      pr_uuid = open_pr(ctx, a_uuid, b_uuid)

      context = %{view_uuid: pr_uuid, args: %{}, signing_context: ctx, source: "test"}

      assert {:error, "missing required arg: text"} =
               ViewActionDispatch.dispatch("pr_comment", context)
    end
  end
end

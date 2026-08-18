defmodule Commonplace.PrRefreshPreviewTest do
  @moduledoc """
  Tests for the `pr_refresh_preview` verb (design doc
  docs/plans/2026-07-16-intra-repo-pull-request-design.md §7.3,
  commonplace-plan repo).

  Fixture setup mirrors `Commonplace.PrOpenTest` — the dispatcher's
  `pr_refresh_preview` handler talks to the default-named `CommitStore`
  via `CommitStoreClient`, plus `CommandRouter.fork/2`'s default
  `__MODULE__` server, so this needs the same "root pointer file +
  running default CommitStore" fixture as `pr_open`, not a custom-named
  store the dispatcher/router singleton can't see.
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
    dir = Path.join(System.tmp_dir!(), "cp_pr_refresh_test_#{:rand.uniform(1_000_000_000)}")
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

      # sol/s-snapshot-fresh-s3: the store expands its data_dir at init (the
      # relative-path/cwd-split fix), so assert the EXPANDED path — the intent
      # is "the restored singleton points at this store", not a string form.
      assert CubDB.data_dir(CommitStore.db_handle(CommitStore)) ==
               Path.expand(Path.join(restored_data_dir, "commits"))
    end)

    {pub, priv} = Signing.generate_keypair()

    signing_context = %SigningContext{
      identity_uuid: "test-pr-refresher",
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

  defp open_pr(root_uuid, ctx, a_uuid, b_uuid) do
    context = %{
      view_uuid: b_uuid,
      args: %{"target" => a_uuid},
      signing_context: ctx,
      source: "test"
    }

    {:ok, :tree_mutation, details} = ViewActionDispatch.dispatch("pr_open", context)
    _ = root_uuid
    details.pr_uuid
  end

  defp set_pr_status(pr_uuid, status) do
    {:ok, doc} = DocBuilder.reconstruct_doc(CommitStoreClient, pr_uuid)
    content = Commonplace.Document.ContentType.get_content(doc)
    new_content = Regex.replace(~r/status="open"/, content, "status=\"#{status}\"")
    doc = Commonplace.Document.Diff.apply_diff(doc, content, new_content)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStoreClient.create_chained_commit(CommitStoreClient, pr_uuid, update)
  end

  defp latest_commit_id(uuid) do
    case CommitStoreClient.latest_commit(uuid) do
      {:ok, commit} -> commit.id
      :none -> nil
    end
  end

  describe "pr_refresh_preview (§7.3)" do
    test "refreshes the preview section with a merge summary + result_hash, leaving the real target untouched",
         %{root: root_uuid, signing_context: ctx} do
      a_uuid = create_leaf_doc("original content")
      {:ok, b_uuid} = CommandRouter.fork(a_uuid)
      {:ok, _} = CommandRouter.write(b_uuid, "edited in the fork")

      pr_uuid = open_pr(root_uuid, ctx, a_uuid, b_uuid)

      target_head_before = latest_commit_id(a_uuid)

      refresh_context = %{view_uuid: pr_uuid, signing_context: ctx, source: "test"}

      assert {:ok, :tree_mutation, details} =
               ViewActionDispatch.dispatch("pr_refresh_preview", refresh_context)

      assert details.action == "pr_refresh_preview"
      assert details.pr_uuid == pr_uuid
      assert is_binary(details.result_hash)

      content = pr_doc_content(pr_uuid)
      refute content =~ "no preview yet"
      assert content =~ "merge-summary"
      assert content =~ "result-hash"
      assert content =~ details.result_hash
      assert content =~ "edited in the fork"
      assert content =~ "scratch-head"
      assert content =~ "informational-only"

      # Statelessness pin (§7.3): the REAL target is untouched — same
      # latest commit before and after the preview refresh.
      assert latest_commit_id(a_uuid) == target_head_before
    end

    test "a second refresh after another edit changes the preview + result_hash, target still untouched",
         %{root: root_uuid, signing_context: ctx} do
      a_uuid = create_leaf_doc("original content")
      {:ok, b_uuid} = CommandRouter.fork(a_uuid)
      {:ok, _} = CommandRouter.write(b_uuid, "first edit")

      pr_uuid = open_pr(root_uuid, ctx, a_uuid, b_uuid)

      target_head_before = latest_commit_id(a_uuid)

      refresh_context = %{view_uuid: pr_uuid, signing_context: ctx, source: "test"}

      assert {:ok, :tree_mutation, details1} =
               ViewActionDispatch.dispatch("pr_refresh_preview", refresh_context)

      {:ok, _} = CommandRouter.write(b_uuid, "second edit, changed again")

      assert {:ok, :tree_mutation, details2} =
               ViewActionDispatch.dispatch("pr_refresh_preview", refresh_context)

      refute details1.result_hash == details2.result_hash

      content = pr_doc_content(pr_uuid)
      assert content =~ "second edit, changed again"
      assert content =~ details2.result_hash
      refute content =~ details1.result_hash

      assert latest_commit_id(a_uuid) == target_head_before
    end

    # Designer review-sensitive property (#8390): the result_hash becomes
    # 7.4's staleness RE-DERIVATION comparand — the projection must be
    # byte-stable across runs on IDENTICAL state, else accept would
    # spuriously refuse fresh PRs. Two refreshes with no intervening
    # edits must hash identically (fresh scratch fork each run, so this
    # also pins that fork+merge is deterministic w.r.t. the projection).
    test "DETERMINISM: two refreshes on identical state produce the SAME result_hash",
         %{root: root_uuid, signing_context: ctx} do
      a_uuid = create_leaf_doc("original content")
      {:ok, b_uuid} = CommandRouter.fork(a_uuid)
      {:ok, _} = CommandRouter.write(b_uuid, "one deterministic edit")

      pr_uuid = open_pr(root_uuid, ctx, a_uuid, b_uuid)
      refresh_context = %{view_uuid: pr_uuid, signing_context: ctx, source: "test"}

      assert {:ok, :tree_mutation, d1} =
               ViewActionDispatch.dispatch("pr_refresh_preview", refresh_context)

      assert {:ok, :tree_mutation, d2} =
               ViewActionDispatch.dispatch("pr_refresh_preview", refresh_context)

      assert d1.result_hash == d2.result_hash,
             "projection is NOT byte-stable across identical-state refreshes — " <>
               "7.4's re-derivation compare would spuriously refuse (STOP: designer must rule)"
    end

    test "refresh on a non-open PR is refused", %{root: root_uuid, signing_context: ctx} do
      a_uuid = create_leaf_doc("original content")
      {:ok, b_uuid} = CommandRouter.fork(a_uuid)
      {:ok, _} = CommandRouter.write(b_uuid, "edited in the fork")

      pr_uuid = open_pr(root_uuid, ctx, a_uuid, b_uuid)
      set_pr_status(pr_uuid, "merged")

      refresh_context = %{view_uuid: pr_uuid, signing_context: ctx, source: "test"}

      assert {:error, "PR is not open"} =
               ViewActionDispatch.dispatch("pr_refresh_preview", refresh_context)
    end

    test "the scratch fork is not reachable from the root schema",
         %{root: root_uuid, signing_context: ctx} do
      a_uuid = create_leaf_doc("original content")
      {:ok, b_uuid} = CommandRouter.fork(a_uuid)
      {:ok, _} = CommandRouter.write(b_uuid, "edited in the fork")

      pr_uuid = open_pr(root_uuid, ctx, a_uuid, b_uuid)

      # Root schema entries + __pulls/ dir entries BEFORE the refresh —
      # `pr_open` (§7.2) already attached the PR doc, so this snapshot
      # is "what pr_open produced," the baseline `pr_refresh_preview`
      # must not add to.
      root_entries_before = root_schema_entry_ids(root_uuid)
      {:ok, pulls_entry} = get_pulls_entry(root_uuid)
      pulls_entries_before = schema_entry_ids(pulls_entry.node_id)

      refresh_context = %{view_uuid: pr_uuid, signing_context: ctx, source: "test"}

      assert {:ok, :tree_mutation, _details} =
               ViewActionDispatch.dispatch("pr_refresh_preview", refresh_context)

      # No new entry appeared anywhere in the schema tree the scratch
      # fork could have been attached under — it was born unreachable
      # and stays that way.
      assert root_schema_entry_ids(root_uuid) == root_entries_before
      assert schema_entry_ids(pulls_entry.node_id) == pulls_entries_before
      assert pulls_entries_before == MapSet.new([pr_uuid])
    end
  end

  defp get_pulls_entry(root_uuid) do
    {:ok, root_doc} = DocBuilder.reconstruct_snapshot(CommitStoreClient, root_uuid)
    Schema.get_entry(root_doc, "__pulls")
  end

  defp root_schema_entry_ids(uuid), do: schema_entry_ids(uuid)

  defp schema_entry_ids(uuid) do
    {:ok, doc} = DocBuilder.reconstruct_snapshot(CommitStoreClient, uuid)
    Schema.list_entries(doc) |> Enum.map(& &1.node_id) |> MapSet.new()
  end
end

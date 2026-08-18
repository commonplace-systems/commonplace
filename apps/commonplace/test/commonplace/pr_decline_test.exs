defmodule Commonplace.PrDeclineTest do
  @moduledoc """
  Tests for the `pr_decline` verb (design doc
  docs/plans/2026-07-16-intra-repo-pull-request-design.md §7.4,
  commonplace-plan repo), including designer ruling #8390-1: the
  opener-decline branch requires BOTH the PR's recorded `opened_by`
  AND the current session's principal to be signing-context-derived —
  an anonymous-opened PR confers no opener rights.

  Fixture pattern mirrors `Commonplace.PrAcceptTest` /
  `Commonplace.PrRefreshPreviewTest`.
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
    dir = Path.join(System.tmp_dir!(), "cp_pr_decline_test_#{:rand.uniform(1_000_000_000)}")
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

    opener_ctx = %SigningContext{
      identity_uuid: "test-pr-opener",
      private_key: priv,
      public_key: pub
    }

    %{root: root_uuid, opener_ctx: opener_ctx}
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

  defp open_pr(ctx_or_nil, a_uuid, b_uuid) do
    base_context = %{view_uuid: b_uuid, args: %{"target" => a_uuid}, source: "test"}

    context =
      case ctx_or_nil do
        nil -> base_context
        ctx -> Map.put(base_context, :signing_context, ctx)
      end

    {:ok, :tree_mutation, details} = ViewActionDispatch.dispatch("pr_open", context)
    details.pr_uuid
  end

  defp decline_pr(pr_uuid, ctx_or_nil) do
    base_context = %{view_uuid: pr_uuid, source: "test"}

    context =
      case ctx_or_nil do
        nil -> base_context
        ctx -> Map.put(base_context, :signing_context, ctx)
      end

    ViewActionDispatch.dispatch("pr_decline", context)
  end

  describe "pr_decline (permissive default — any signing_context counts as target-writer)" do
    test "target-write holder can decline; status -> declined, source B untouched", %{
      opener_ctx: opener_ctx
    } do
      a_uuid = create_leaf_doc("original content")
      {:ok, b_uuid} = CommandRouter.fork(a_uuid)
      {:ok, _} = CommandRouter.write(b_uuid, "edited in the fork")

      pr_uuid = open_pr(opener_ctx, a_uuid, b_uuid)

      {pub, priv} = Signing.generate_keypair()

      decliner_ctx = %SigningContext{
        identity_uuid: "test-pr-target-writer",
        private_key: priv,
        public_key: pub
      }

      assert {:ok, :tree_mutation, details} = decline_pr(pr_uuid, decliner_ctx)
      assert details.action == "pr_decline"
      assert details.result == :declined

      content = pr_doc_content(pr_uuid)
      expected_decliner = Signing.signer_id(decliner_ctx.identity_uuid, decliner_ctx.public_key)
      assert content =~ ~s(status="declined")
      assert content =~ ~s(declined_by="#{expected_decliner}")

      # source B untouched — still readable, unedited.
      {:ok, b_doc} = DocBuilder.reconstruct_doc(CommitStoreClient, b_uuid)
      assert Commonplace.Document.ContentType.get_content(b_doc) == "edited in the fork"
    end

    test "the PR's own opener (signing-context-derived) can decline", %{opener_ctx: opener_ctx} do
      a_uuid = create_leaf_doc("original content")
      {:ok, b_uuid} = CommandRouter.fork(a_uuid)

      pr_uuid = open_pr(opener_ctx, a_uuid, b_uuid)

      assert {:ok, :tree_mutation, details} = decline_pr(pr_uuid, opener_ctx)
      assert details.result == :declined
    end

    test "declined PR can't be declined again (not open)", %{opener_ctx: opener_ctx} do
      a_uuid = create_leaf_doc("original content")
      {:ok, b_uuid} = CommandRouter.fork(a_uuid)
      pr_uuid = open_pr(opener_ctx, a_uuid, b_uuid)

      assert {:ok, :tree_mutation, _} = decline_pr(pr_uuid, opener_ctx)
      assert {:error, "PR is not open"} = decline_pr(pr_uuid, opener_ctx)
    end
  end

  describe "pr_decline — designer ruling #8390-1 (anonymous-opened PR, enforce mode)" do
    # Isolates the OPENER rule from the permissive default's
    # "everyone is a target-writer" short-circuit: under enforce with
    # an empty explicit trusted_identities set, neither the anonymous
    # opener nor the anonymous decliner holds target-:write (no certs,
    # not pinned), so only the opener-rule branch is at stake.
    #
    # Mirrors `Commonplace.Tree.MergeTest`'s "merge/4 signing plumb"
    # ordering discipline: build the fork/pr_open fixture FIRST under
    # the default permissive config (`CommandRouter.fork/2`'s scratch
    # commits are always unsigned — a pre-existing gap outside this
    # slice's scope, see the STOP item in `Commonplace.PrAcceptTest`),
    # THEN flip to strict+enforce for the decline call under test.
    test "an anonymous session cannot decline another anonymous session's anonymously-opened PR" do
      a_uuid = create_leaf_doc("original content")
      {:ok, b_uuid} = CommandRouter.fork(a_uuid)

      # `nil` signing_context on open -> opened_by falls back to
      # "anonymous@local" (`resolve_principal/1`'s fallback).
      pr_uuid = open_pr(nil, a_uuid, b_uuid)
      assert pr_doc_content(pr_uuid) =~ ~s(opened_by="anonymous@local")

      old_trust = Application.get_env(:commonplace, :trust)
      old_knob = Application.get_env(:commonplace, :local_write_gate)

      Application.put_env(:commonplace, :trust, %{
        accept_unsigned: false,
        trusted_identities: %{}
      })

      Application.put_env(:commonplace, :local_write_gate, :enforce)

      on_exit(fn ->
        case old_trust do
          nil -> Application.delete_env(:commonplace, :trust)
          v -> Application.put_env(:commonplace, :trust, v)
        end

        case old_knob do
          nil -> Application.delete_env(:commonplace, :local_write_gate)
          v -> Application.put_env(:commonplace, :local_write_gate, v)
        end
      end)

      # A second anonymous session (also no signing_context) attempts
      # to decline. Under enforce, it holds no target-:write (no certs,
      # not pinned) AND the opener-rule requires a REAL
      # signing-context-derived match on BOTH sides — an anonymous
      # decliner's `session_signing_principal/1` is `nil`, which can
      # never equal the recorded "anonymous@local".
      assert {:error, "you are not authorized to decline this PR"} = decline_pr(pr_uuid, nil)

      assert pr_doc_content(pr_uuid) =~ ~s(status="open")
    end
  end
end

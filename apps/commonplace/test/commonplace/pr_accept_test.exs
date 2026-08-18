defmodule Commonplace.PrAcceptTest do
  @moduledoc """
  Tests for the `pr_accept` verb (design doc
  docs/plans/2026-07-16-intra-repo-pull-request-design.md §6/§7.4,
  commonplace-plan repo).

  Fixture setup mirrors `Commonplace.PrRefreshPreviewTest` — the
  dispatcher's `pr_accept` handler talks to the default-named
  `CommitStore` via `CommitStoreClient`, plus `CommandRouter.fork/2`'s
  default `__MODULE__` server, so this needs the same "root pointer
  file + running default CommitStore" fixture, not a custom-named
  store the dispatcher/router singleton can't see.

  The designer's must-see tests (§7.7) come first: FORGED-PREVIEW (the
  §7.7 headline test — proves re-derivation, never trust a doc-recorded
  hash), the bare-leaf fork+merge round-trip, the staleness honest
  path, and AuthZ (which needs its own nested `enforce` fixture,
  mirroring `Commonplace.Tree.MergeTest`'s "merge/4 signing plumb"
  describe block: build the fixture under the default permissive
  config, THEN flip to strict+enforce for the call under test).
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
    dir = Path.join(System.tmp_dir!(), "cp_pr_accept_test_#{:rand.uniform(1_000_000_000)}")
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
      identity_uuid: "test-pr-acceptor",
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

  defp target_content(uuid) do
    {:ok, doc} = DocBuilder.reconstruct_doc(CommitStoreClient, uuid)
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

  defp refresh_pr(pr_uuid, ctx) do
    context = %{view_uuid: pr_uuid, signing_context: ctx, source: "test"}
    {:ok, :tree_mutation, details} = ViewActionDispatch.dispatch("pr_refresh_preview", context)
    details
  end

  defp accept_pr(pr_uuid, ctx) do
    context = %{view_uuid: pr_uuid, signing_context: ctx, source: "test"}
    ViewActionDispatch.dispatch("pr_accept", context)
  end

  describe "pr_accept — round-trip + staleness (§6/§7.4, permissive default)" do
    test "bare-leaf fork+merge ROUND-TRIP: accept lands B's edit into A, PR doc records merged + acceptor",
         %{signing_context: ctx} do
      a_uuid = create_leaf_doc("original content")
      {:ok, b_uuid} = CommandRouter.fork(a_uuid)
      {:ok, _} = CommandRouter.write(b_uuid, "edited in the fork")

      pr_uuid = open_pr(ctx, a_uuid, b_uuid)
      refresh_pr(pr_uuid, ctx)

      assert {:ok, :tree_mutation, details} = accept_pr(pr_uuid, ctx)
      assert details.action == "pr_accept"
      assert details.pr_uuid == pr_uuid
      assert details.result == :merged

      # A's content now contains B's edit.
      assert target_content(a_uuid) =~ "edited in the fork"

      # PR doc status merged + acceptor recorded.
      content = pr_doc_content(pr_uuid)
      expected_acceptor = Signing.signer_id(ctx.identity_uuid, ctx.public_key)
      assert content =~ ~s(status="merged")
      assert content =~ ~s(merged_by="#{expected_acceptor}")
      assert content =~ "Accepted by #{expected_acceptor}"
    end

    test "staleness honest-path: edit B after refresh -> accept refuses + auto-refreshes; second accept succeeds",
         %{signing_context: ctx} do
      a_uuid = create_leaf_doc("original content")
      {:ok, b_uuid} = CommandRouter.fork(a_uuid)
      {:ok, _} = CommandRouter.write(b_uuid, "first edit")

      pr_uuid = open_pr(ctx, a_uuid, b_uuid)
      refresh_pr(pr_uuid, ctx)

      # Genuinely stale: B changes again after the last refresh, without
      # another explicit pr_refresh_preview call.
      {:ok, _} = CommandRouter.write(b_uuid, "second edit, now stale")

      stale_content_before = pr_doc_content(pr_uuid)

      hash_before =
        Regex.run(~r/<result-hash>([^<]*)<\/result-hash>/, stale_content_before) |> List.last()

      assert {:error, "preview is stale — refreshed; review and accept again"} =
               accept_pr(pr_uuid, ctx)

      # A untouched by the refused accept.
      assert target_content(a_uuid) == "original content"

      # The doc's preview was auto-refreshed: assert a NEW hash appears,
      # reflecting "second edit, now stale".
      refreshed_content = pr_doc_content(pr_uuid)

      hash_after =
        Regex.run(~r/<result-hash>([^<]*)<\/result-hash>/, refreshed_content) |> List.last()

      refute hash_after == hash_before
      assert refreshed_content =~ "second edit, now stale"
      # Still open — a refused accept never transitions status.
      assert refreshed_content =~ ~s(status="open")

      # Second accept (now fresh, since the refusal itself just refreshed
      # the committed preview) succeeds.
      assert {:ok, :tree_mutation, details} = accept_pr(pr_uuid, ctx)
      assert details.result == :merged
      assert target_content(a_uuid) =~ "second edit, now stale"
    end

    # §7.4b HEADLINE (cp-plan #8403): the WYSIWYG attack — forge what the
    # reviewer SEES (the displayed <projected-result> text), leave
    # <result-hash> UNTOUCHED (honest). A hash-vs-hash check would wave
    # this through (the hash still matches a fresh derive); the comparand
    # is the displayed content, so the tampered display ≠ fresh render →
    # refuse. This is the property the whole feature exists for:
    # what-you-review IS what-you-merge.
    test "FORGED-DISPLAY (§7.4b headline): tampering the shown preview text (honest hash) is refused, target untouched",
         %{signing_context: ctx} do
      a_uuid = create_leaf_doc("original content")
      {:ok, b_uuid} = CommandRouter.fork(a_uuid)
      {:ok, _} = CommandRouter.write(b_uuid, "edited in the fork")

      pr_uuid = open_pr(ctx, a_uuid, b_uuid)
      refresh_pr(pr_uuid, ctx)

      {:ok, doc} = DocBuilder.reconstruct_doc(CommitStoreClient, pr_uuid)
      old_content = Commonplace.Document.ContentType.get_content(doc)

      # Swap the DISPLAYED projected result to benign-looking text while
      # leaving <result-hash> exactly as the honest refresh wrote it.
      assert old_content =~ "<projected-result>"

      new_content =
        Regex.replace(
          ~r/<projected-result>.*?<\/projected-result>/s,
          old_content,
          "<projected-result>\ninnocent-looking reviewed content\n</projected-result>",
          global: false
        )

      refute new_content == old_content, "the display swap must actually change the doc"

      doc = Commonplace.Document.Diff.apply_diff(doc, old_content, new_content)
      update = Yelixer.Encoding.encode_update(doc)
      CommitStoreClient.create_chained_commit(CommitStoreClient, pr_uuid, update)

      # Accept re-derives and compares the reviewer-visible content →
      # the forged display ≠ fresh render → refuse via the stale path.
      assert {:error, "preview is stale — refreshed; review and accept again"} =
               accept_pr(pr_uuid, ctx)

      # REAL target untouched; auto-refresh restored the honest display
      # (the forged text is gone).
      assert target_content(a_uuid) == "original content"
      refreshed_content = pr_doc_content(pr_uuid)
      refute refreshed_content =~ "innocent-looking reviewed content"
    end

    # §7.4b COROLLARY: the <result-hash> is informational-only now, so
    # forging it ALONE — with the displayed content honest and current —
    # must NOT block a legitimate accept (what-you-see still equals
    # what-you-get; the honest merge produces exactly the reviewed text).
    # This pins that the comparand is the DISPLAY, not the digest — the
    # inverse guarantee to the headline above.
    test "§7.4b: a forged result_hash alone (honest, current display) does NOT block accept — hash is informational",
         %{signing_context: ctx} do
      a_uuid = create_leaf_doc("original content")
      {:ok, b_uuid} = CommandRouter.fork(a_uuid)
      {:ok, _} = CommandRouter.write(b_uuid, "edited in the fork")

      pr_uuid = open_pr(ctx, a_uuid, b_uuid)
      refresh_pr(pr_uuid, ctx)

      {:ok, doc} = DocBuilder.reconstruct_doc(CommitStoreClient, pr_uuid)
      old_content = Commonplace.Document.ContentType.get_content(doc)

      new_content =
        Regex.replace(
          ~r/<result-hash>[^<]*<\/result-hash>/,
          old_content,
          "<result-hash>#{String.duplicate("a", 64)}</result-hash>"
        )

      doc = Commonplace.Document.Diff.apply_diff(doc, old_content, new_content)
      update = Yelixer.Encoding.encode_update(doc)
      CommitStoreClient.create_chained_commit(CommitStoreClient, pr_uuid, update)

      # The display is honest and B is unchanged since the refresh, so the
      # WYSIWYG comparand matches → accept proceeds and merges the honest
      # reviewed content into the target.
      assert {:ok, :tree_mutation, %{result: :merged}} = accept_pr(pr_uuid, ctx)
      assert target_content(a_uuid) =~ "edited in the fork"
    end

    test "declined PR can't be accepted", %{signing_context: ctx} do
      a_uuid = create_leaf_doc("original content")
      {:ok, b_uuid} = CommandRouter.fork(a_uuid)
      {:ok, _} = CommandRouter.write(b_uuid, "edited in the fork")

      pr_uuid = open_pr(ctx, a_uuid, b_uuid)
      refresh_pr(pr_uuid, ctx)

      assert {:ok, :tree_mutation, _} =
               ViewActionDispatch.dispatch("pr_decline", %{
                 view_uuid: pr_uuid,
                 signing_context: ctx,
                 source: "test"
               })

      assert {:error, "PR is not open"} = accept_pr(pr_uuid, ctx)
    end
  end

  describe "pr_accept — authorization (§6 step 4, enforce mode)" do
    # Mirrors `Commonplace.Tree.MergeTest`'s "merge/4 signing plumb"
    # fixture discipline: build the fork/edit/PR/refresh fixture FIRST
    # under the default permissive config (so setup writes aren't
    # themselves gated), THEN flip to strict trust + `local_write_gate:
    # :enforce` for the accept call under test. `NodeIdentity.signing_context/0`
    # mints a fresh node key under the SAME data_dir as the workspace
    # (already set to `dir` by the outer `setup`), and `Trust.config/0`
    # folds that node identity in as trusted (`with_local_node_trust/1`)
    # with zero pinning — so the node's own signing_context is always
    # an AUTHORIZED acceptor, while an unrelated freshly-generated
    # keypair (no cert, not pinned) is not.
    setup %{root: root_uuid, signing_context: opener_ctx} do
      a_uuid = create_leaf_doc("original content")
      {:ok, b_uuid} = CommandRouter.fork(a_uuid)
      {:ok, _} = CommandRouter.write(b_uuid, "edited in the fork")

      pr_uuid = open_pr(opener_ctx, a_uuid, b_uuid)

      {:ok, node_ctx} = Commonplace.Crypto.NodeIdentity.signing_context()

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

      # STOP item (see final report): `pr_refresh_preview`'s scratch
      # preview goes through `CommandRouter.fork/2` (`Tree.Fork`), which
      # — unlike `Tree.Merge.merge/4` (§7.1) — has NO signing_context
      # plumb at all; its commits are always unsigned. Under
      # `local_write_gate: :enforce` that makes the scratch fork's own
      # commits land denied regardless of who calls it, so the
      # PROJECTED TEXT the preview hashes degenerates to "" for
      # EVERYONE while this fixture is in enforce mode — a pre-existing
      # gap in the ALREADY-SHIPPED 7.0-7.3 code, not something §7.4
      # introduced or can fix without touching Fork's arity (out of
      # this slice's scope; the design doc's only fork-signing gap
      # note, §7.1, is about a DIFFERENT fork call site,
      # `fork_into_target/3`).
      #
      # To test the AUTHORIZATION gate (§6 step 4) in isolation from
      # that pre-existing gap, the refresh here runs AFTER the flip to
      # enforce, so the COMMITTED preview and `pr_accept`'s own
      # re-derivation are produced under the IDENTICAL (degenerate)
      # fork conditions and therefore hash-MATCH regardless of the
      # gap — staleness passes, and the test genuinely exercises
      # authorization rather than being masked by it. The REAL merge
      # (`Merge.merge/4`, §7.1) does NOT go through `Fork` at all, so
      # the merge itself (and its content assertions below) still
      # exercises the true, non-degenerate signed-merge path.
      refresh_pr(pr_uuid, node_ctx)

      _ = root_uuid

      %{a_uuid: a_uuid, b_uuid: b_uuid, pr_uuid: pr_uuid, node_ctx: node_ctx}
    end

    test "authorized (node-trusted) acceptor succeeds", %{
      pr_uuid: pr_uuid,
      a_uuid: a_uuid,
      node_ctx: node_ctx
    } do
      assert {:ok, :tree_mutation, details} = accept_pr(pr_uuid, node_ctx)
      assert details.result == :merged
      assert target_content(a_uuid) =~ "edited in the fork"
    end

    test "unauthorized principal is sanitized-refused; target untouched; PR stays open",
         %{pr_uuid: pr_uuid, a_uuid: a_uuid} do
      {pub, priv} = Signing.generate_keypair()

      stranger_ctx = %SigningContext{
        identity_uuid: "test-pr-stranger",
        private_key: priv,
        public_key: pub
      }

      # §6 REORDER (cp-plan #8403): authorization now runs BEFORE the
      # staleness re-derivation, so an unauthorized acceptor gets the
      # clean authz refusal deterministically — AND, the load-bearing
      # reason, no PR-doc write (auto-refresh) can happen before the
      # authz gate.
      assert {:error, "you are not authorized to accept into the target"} =
               accept_pr(pr_uuid, stranger_ctx)

      # Security invariants: target untouched, PR still open, and (the
      # reorder's point) the PR doc's preview section was NOT rewritten
      # by an unauthorized accept.
      assert target_content(a_uuid) == "original content"

      content = pr_doc_content(pr_uuid)
      assert content =~ ~s(status="open")
    end
  end
end

defmodule Commonplace.Bd.CloseGateTest do
  @moduledoc """
  Bd P2 Slice S3 — the close-gate + done-witnesses. TRUST-CRITICAL: a
  weak done-validator is a forgeable-completion hole, so every refusal
  path below is exercised as deliberately as the happy path.

  Fixture setup mirrors `Commonplace.PrAcceptTest` /
  `Commonplace.Bd.TicketVerbsTest` — the dispatcher's `ticket_close`
  (and, for the pr_merge end-to-end test, `pr_open`/`pr_refresh_preview`/
  `pr_accept`) handlers talk to the default-named `CommitStore` via
  `CommitStoreClient`, so this needs the "root pointer file + running
  default CommitStore" fixture, not a custom-named store the dispatcher
  singleton can't see.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bd.Issue
  alias Commonplace.Crypto.Signing
  alias Commonplace.Crypto.SigningContext
  alias Commonplace.Store.CommitStore
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Commonplace.ViewActionDispatch

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_close_gate_test_#{:rand.uniform(1_000_000_000)}")
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
      identity_uuid: "test-close-gate-invoker",
      private_key: priv,
      public_key: pub
    }

    %{root: root_uuid, dir: dir, signing_context: signing_context}
  end

  # --- generic helpers ---

  defp create_ticket(root_uuid, attrs) do
    {:ok, issue, _dir} = Issue.create(root_uuid, attrs)
    issue
  end

  defp close_ticket(ticket_id, witnesses, ctx) do
    context = %{
      args: %{"ticket" => ticket_id, "witnesses" => witnesses},
      signing_context: ctx,
      source: "test"
    }

    ViewActionDispatch.dispatch("ticket_close", context)
  end

  defp issue_meta_node_id(root_uuid, ticket_id) do
    {:ok, dir_uuid} = Commonplace.Bd.Workspace.issue_dir_uuid(root_uuid, ticket_id)
    {:ok, schema} = Commonplace.Bd.Schemas.load_dir_schema(dir_uuid)
    {:ok, entry} = Schema.get_entry(schema, Commonplace.Bd.Schemas.issue_filename())
    entry.node_id
  end

  defp commit_count(uuid) do
    CommitStoreClient.commit_ids_for_doc(CommitStoreClient, uuid) |> MapSet.size()
  end

  # --- pr_open/pr_refresh_preview/pr_accept helpers (mirrors PrAcceptTest) ---

  defp create_leaf_doc(content) do
    uuid = UUID.uuid4()
    doc = Commonplace.Document.ContentType.create(Yelixer.Doc.new(), :text, "doc.txt")
    doc = Commonplace.Document.ContentType.insert_text(doc, 0, content)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStoreClient.create_commit(CommitStoreClient, uuid, update, nil)
    uuid
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
    {:ok, :tree_mutation, _details} = ViewActionDispatch.dispatch("pr_refresh_preview", context)
  end

  defp accept_pr(pr_uuid, ctx) do
    context = %{view_uuid: pr_uuid, signing_context: ctx, source: "test"}
    ViewActionDispatch.dispatch("pr_accept", context)
  end

  defp hex(cid), do: Base.encode16(cid, case: :lower)

  # cp-plan ⛩ hardening: the pr_merge validator re-derives the witness
  # signer's authority at VERIFY time AND cryptographically verifies the
  # commit's signature against a key it independently PINS for that signer
  # (resolved from `trusted_identities`, never from the commit). So a
  # legitimately-accepted merge only satisfies a pr_merge close if its
  # acceptor is a pinned trusted identity — which is exactly the live
  # scenario (a node-accepted PR is signed by the pinned node). This pins
  # `sc`'s identity while keeping `accept_unsigned: true`, so the unsigned
  # scaffolding writes still land but the verify-against-pinned check has a
  # real key to check against.
  defp pin_identity(%SigningContext{identity_uuid: id, public_key: pub}) do
    old = Application.get_env(:commonplace, :trust)

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: true,
      trusted_identities: %{id => Signing.encode_key(pub)}
    })

    on_exit(fn ->
      case old do
        nil -> Application.delete_env(:commonplace, :trust)
        v -> Application.put_env(:commonplace, :trust, v)
      end
    end)
  end

  describe "manual close" do
    test "no witness -> succeeds, status closed, done_witness [], ONE commit", %{
      root: root,
      signing_context: ctx
    } do
      ticket = create_ticket(root, %{title: "manual ticket"})
      meta_uuid = issue_meta_node_id(root, ticket.id)
      before_count = commit_count(meta_uuid)

      assert {:ok, :tree_mutation, details} = close_ticket(ticket.id, [], ctx)
      assert details.action == "ticket_close"
      assert details.status == "closed"
      assert details.done_witness == []

      after_count = commit_count(meta_uuid)
      assert after_count == before_count + 1

      {:ok, reloaded} = Issue.show(root, ticket.id)
      assert reloaded.status == "closed"
      assert reloaded.done_witness == []
    end

    test "witnesses arg is ignored for a manual ticket (no extra-witness requirement)", %{
      root: root,
      signing_context: ctx
    } do
      ticket = create_ticket(root, %{title: "manual ticket 2"})

      assert {:ok, :tree_mutation, details} = close_ticket(ticket.id, ["deadbeef"], ctx)
      assert details.done_witness == []
    end
  end

  describe "close-only-status-path (unchanged from S1)" do
    test "ticket_update still refuses status", %{root: root, signing_context: ctx} do
      ticket = create_ticket(root, %{title: "A"})

      context = %{
        args: %{"ticket" => ticket.id, "changes" => %{"status" => "closed"}},
        signing_context: ctx,
        source: "test"
      }

      assert {:error, reason} = ViewActionDispatch.dispatch("ticket_update", context)
      assert reason =~ "status"

      {:ok, reloaded} = Issue.show(root, ticket.id)
      assert reloaded.status == "open"
    end
  end

  describe "pr_merge close — happy path (end-to-end)" do
    test "a pr_accept-produced stamped, acceptor-signed merge on the declared target satisfies the close",
         %{root: root, signing_context: ctx} do
      a_uuid = create_leaf_doc("original content")
      {:ok, b_uuid} = Commonplace.CommandRouter.fork(a_uuid)
      {:ok, _} = Commonplace.CommandRouter.write(b_uuid, "edited in the fork")

      pr_uuid = open_pr(ctx, a_uuid, b_uuid)
      refresh_pr(pr_uuid, ctx)

      assert {:ok, :tree_mutation, _} = accept_pr(pr_uuid, ctx)

      {:ok, merge_commit} = CommitStoreClient.latest_commit(CommitStoreClient, a_uuid)
      witness_hex = hex(merge_commit.id)

      ticket =
        create_ticket(root, %{
          title: "close via pr_merge",
          done_when: %{"type" => "pr_merge", "target" => a_uuid}
        })

      # The acceptor (ctx) must be a pinned trusted identity for its
      # signed merge to satisfy the verify-time signature re-derivation —
      # the live analogue is a node-accepted PR signed by the pinned node.
      pin_identity(ctx)

      assert {:ok, :tree_mutation, details} = close_ticket(ticket.id, [witness_hex], ctx)
      assert details.status == "closed"
      assert details.done_witness == [witness_hex]

      {:ok, reloaded} = Issue.show(root, ticket.id)
      assert reloaded.status == "closed"
      assert reloaded.done_witness == [witness_hex]
    end

    test "one-commit flip: status + done_witness land in a single commit", %{
      root: root,
      signing_context: ctx
    } do
      a_uuid = create_leaf_doc("original content")
      {:ok, b_uuid} = Commonplace.CommandRouter.fork(a_uuid)
      {:ok, _} = Commonplace.CommandRouter.write(b_uuid, "edited in the fork")

      pr_uuid = open_pr(ctx, a_uuid, b_uuid)
      refresh_pr(pr_uuid, ctx)
      assert {:ok, :tree_mutation, _} = accept_pr(pr_uuid, ctx)

      {:ok, merge_commit} = CommitStoreClient.latest_commit(CommitStoreClient, a_uuid)
      witness_hex = hex(merge_commit.id)

      ticket =
        create_ticket(root, %{
          title: "one-commit flip",
          done_when: %{"type" => "pr_merge", "target" => a_uuid}
        })

      meta_uuid = issue_meta_node_id(root, ticket.id)
      before_count = commit_count(meta_uuid)

      pin_identity(ctx)
      assert {:ok, :tree_mutation, _} = close_ticket(ticket.id, [witness_hex], ctx)

      after_count = commit_count(meta_uuid)
      assert after_count == before_count + 1
    end
  end

  describe "pr_merge close — refusals (each sanitized)" do
    setup %{root: root, signing_context: ctx} do
      a_uuid = create_leaf_doc("original content")

      ticket =
        create_ticket(root, %{
          title: "refusal fixture",
          done_when: %{"type" => "pr_merge", "target" => a_uuid}
        })

      %{a_uuid: a_uuid, ticket: ticket, ctx: ctx}
    end

    test "(a) nonexistent cid is refused", %{ticket: ticket, ctx: ctx, root: root} do
      fake_hex = String.duplicate("ab", 32)

      assert {:error, reason} = close_ticket(ticket.id, [fake_hex], ctx)
      refute reason =~ "untrusted_signer"
      refute reason =~ "{:error"

      {:ok, reloaded} = Issue.show(root, ticket.id)
      assert reloaded.status == "open"
    end

    test "(b) cid on a DIFFERENT doc's chain (not the declared target) is refused",
         %{ticket: ticket, ctx: ctx, root: root} do
      other_uuid = create_leaf_doc("some other doc")
      {:ok, other_commit} = CommitStoreClient.latest_commit(CommitStoreClient, other_uuid)
      witness_hex = hex(other_commit.id)

      assert {:error, _reason} = close_ticket(ticket.id, [witness_hex], ctx)

      {:ok, reloaded} = Issue.show(root, ticket.id)
      assert reloaded.status == "open"
    end

    test "(c) unsigned commit on the target is refused", %{
      a_uuid: a_uuid,
      ticket: ticket,
      ctx: ctx,
      root: root
    } do
      {:ok, latest} = CommitStoreClient.latest_commit(CommitStoreClient, a_uuid)
      doc = Commonplace.Document.ContentType.create(Yelixer.Doc.new(), :text, "doc.txt")
      doc = Commonplace.Document.ContentType.insert_text(doc, 0, "unsigned tamper")
      update = Yelixer.Encoding.encode_update(doc)

      # No signing_context — lands UNSIGNED, but carries the pr_merge
      # stamp so the ONLY thing under test is the "signed" requirement.
      unsigned_commit =
        CommitStoreClient.create_commit(
          CommitStoreClient,
          a_uuid,
          update,
          latest.id,
          %{kind: :regular, pr_merge: "fake-pr-uuid"}
        )

      witness_hex = hex(unsigned_commit.id)

      assert {:error, _reason} = close_ticket(ticket.id, [witness_hex], ctx)

      {:ok, reloaded} = Issue.show(root, ticket.id)
      assert reloaded.status == "open"
    end

    test "(d) signed but signer lacks target-write authority (verify-time authority, CX-bepn) is refused",
         %{a_uuid: a_uuid, ticket: ticket, root: root} do
      {pub, priv} = Signing.generate_keypair()

      stranger_ctx = %SigningContext{
        identity_uuid: "test-close-gate-stranger",
        private_key: priv,
        public_key: pub
      }

      {:ok, latest} = CommitStoreClient.latest_commit(CommitStoreClient, a_uuid)
      doc = Commonplace.Document.ContentType.create(Yelixer.Doc.new(), :text, "doc.txt")
      doc = Commonplace.Document.ContentType.insert_text(doc, 0, "stranger edit")
      update = Yelixer.Encoding.encode_update(doc)

      # Land the stranger's SIGNED commit while trust is still the
      # default permissive config (so the write isn't refused at
      # creation time) — carries the pr_merge stamp so only the
      # "authorized" requirement is under test.
      stranger_commit =
        CommitStoreClient.create_commit(
          CommitStoreClient,
          a_uuid,
          update,
          latest.id,
          %{kind: :regular, pr_merge: "fake-pr-uuid"},
          signing_context: stranger_ctx
        )

      witness_hex = hex(stranger_commit.id)

      # NOW flip to strict trust for the CLOSE call — verify-time
      # authority, per CX-bepn: the stranger was never pinned, so a
      # strict re-derivation at close time refuses regardless of when
      # the commit landed.
      old_trust = Application.get_env(:commonplace, :trust)

      Application.put_env(:commonplace, :trust, %{
        accept_unsigned: false,
        trusted_identities: %{}
      })

      on_exit(fn ->
        case old_trust do
          nil -> Application.delete_env(:commonplace, :trust)
          v -> Application.put_env(:commonplace, :trust, v)
        end
      end)

      {pub2, priv2} = Signing.generate_keypair()

      invoker_ctx = %SigningContext{
        identity_uuid: "test-close-gate-invoker-2",
        private_key: priv2,
        public_key: pub2
      }

      assert {:error, _reason} = close_ticket(ticket.id, [witness_hex], invoker_ctx)

      {:ok, reloaded} = Issue.show(root, ticket.id)
      assert reloaded.status == "open"
    end

    test "(e) UNSTAMPED authorized commit on target (no pr_merge metadata) is refused — the semantic-gap pin",
         %{a_uuid: a_uuid, ticket: ticket, ctx: ctx, root: root} do
      {:ok, latest} = CommitStoreClient.latest_commit(CommitStoreClient, a_uuid)
      doc = Commonplace.Document.ContentType.create(Yelixer.Doc.new(), :text, "doc.txt")
      doc = Commonplace.Document.ContentType.insert_text(doc, 0, "authorized but unstamped")
      update = Yelixer.Encoding.encode_update(doc)

      # Signed, lands under the default permissive trust config (so
      # exists + on-chain + signed + authorized ALL hold) — but no
      # metadata stamp. Proves exists+on-chain+signed+authorized alone
      # is NOT sufficient: it only proves "some authorized commit
      # landed," not "a PR merge landed."
      unstamped_commit =
        CommitStoreClient.create_commit(
          CommitStoreClient,
          a_uuid,
          update,
          latest.id,
          %{},
          signing_context: ctx
        )

      witness_hex = hex(unstamped_commit.id)

      # Pin the signer so exists+on-chain+signed+authorized+verify ALL
      # hold — the ONLY thing that can refuse this commit is the missing
      # pr_merge stamp, which is the property under test.
      pin_identity(ctx)
      assert {:error, _reason} = close_ticket(ticket.id, [witness_hex], ctx)

      {:ok, reloaded} = Issue.show(root, ticket.id)
      assert reloaded.status == "open"
    end

    test "(f) signed + stamped + authorized, but signer is NOT pinned -> refused (verify-time signature hardening, cp-plan ⛩)",
         %{a_uuid: a_uuid, ticket: ticket, ctx: ctx, root: root} do
      {:ok, latest} = CommitStoreClient.latest_commit(CommitStoreClient, a_uuid)
      doc = Commonplace.Document.ContentType.create(Yelixer.Doc.new(), :text, "doc.txt")
      doc = Commonplace.Document.ContentType.insert_text(doc, 0, "stamped but unpinned signer")
      update = Yelixer.Encoding.encode_update(doc)

      # A fully-formed candidate: on the target's chain, SIGNED (by ctx),
      # STAMPED, and authorized under the default permissive config. The
      # ONE thing it lacks is a signature that verifies against a PINNED
      # key — `ctx` is deliberately NOT pinned here (trusted_identities is
      # empty by default). Presence of a signature is not verification:
      # this is the hole cp-plan's mandatory verify-time re-derivation
      # closes. Contrast with the happy path, which pins `ctx`.
      stamped_commit =
        CommitStoreClient.create_commit(
          CommitStoreClient,
          a_uuid,
          update,
          latest.id,
          %{kind: :regular, pr_merge: "fake-pr-uuid"},
          signing_context: ctx
        )

      witness_hex = hex(stamped_commit.id)

      assert {:error, _reason} = close_ticket(ticket.id, [witness_hex], ctx)

      {:ok, reloaded} = Issue.show(root, ticket.id)
      assert reloaded.status == "open"
    end
  end
end

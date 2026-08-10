defmodule Commonplace.PrPreviewReadGuardTest do
  @moduledoc """
  Tests for the 7.3b preview guard (designer review of §7.3 — the
  read-scoping leak shared by §7.4's re-derivation): `derive_preview/4`
  re-reads source/target uuids from the EDITABLE PR doc, so before this
  fix anyone who could write a PR doc could stamp
  `<pr source="ANY-UUID">` and hit refresh/accept to exfiltrate that
  doc's full text into a preview section they can read — a durable
  read-oracle bypassing the P2/P3 read-gating.

  The guard (in the ONE shared derivation path, so refresh AND accept
  both get it, BEFORE the scratch fork):

    1. ancestry re-validation (`find_common_ancestor ≠ :none`) on every
       derive;
    2. invoker read-gate on BOTH uuids via `Trust.Read.authorized?/3`
       with `Trust.ReadMeta.resolve/2`-carried visibility/owner.

  Fixture pattern mirrors `Commonplace.PrRefreshPreviewTest`. The
  read-gate tests flip trust to strict (`accept_unsigned: false`)
  AFTER building the fixture — under the permissive default
  `Trust.reader_authorized?` short-circuits `true` for everyone, so
  only strict mode exercises the deny branch (same staging as the
  P2 MudLive gates).
  """
  use ExUnit.Case, async: false

  alias Commonplace.CommandRouter
  alias Commonplace.Crypto.Signing
  alias Commonplace.Crypto.SigningContext
  alias Commonplace.Store.CommitStore
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Commonplace.ViewActionDispatch

  @secret "TOPSECRET-cabbage-orbit-9931"

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_pr_read_guard_test_#{:rand.uniform(1_000_000_000)}")
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
      identity_uuid: "test-pr-invoker",
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

  # A capability_gated doc in the text-JSON carried shape
  # `Trust.ReadMeta.resolve/2` recognizes (`__room.json` semantics):
  # content Jason-decodes to a map with "visibility"/"owner" keys. The
  # owner is a FOREIGN identity, so the invoking test session is
  # neither owner nor (under strict trust, holding no certs and not
  # pinned) an authorized reader.
  defp create_gated_doc(secret) do
    uuid = UUID.uuid4()

    content =
      Jason.encode!(%{
        "visibility" => "capability_gated",
        "owner" => "stranger-identity",
        "secret" => secret
      })

    doc = Commonplace.Document.ContentType.create(Yelixer.Doc.new(), :text, "__room.json")
    doc = Commonplace.Document.ContentType.insert_text(doc, 0, content)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStoreClient.create_commit(CommitStoreClient, uuid, update, nil)
    uuid
  end

  defp pr_doc_content(pr_uuid) do
    {:ok, doc} = DocBuilder.reconstruct_doc(CommitStoreClient, pr_uuid)
    Commonplace.Document.ContentType.get_content(doc)
  end

  defp doc_content(uuid) do
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

  # THE ATTACK MOVE: the PR doc is an ordinary editable doc, so its
  # `<pr source=... target=.../>` fields can be overwritten directly —
  # this stamps arbitrary uuids over them, exactly what the guard must
  # not trust.
  defp stamp_pr_endpoints(pr_uuid, new_source, new_target) do
    {:ok, doc} = DocBuilder.reconstruct_doc(CommitStoreClient, pr_uuid)
    content = Commonplace.Document.ContentType.get_content(doc)

    new_content =
      content
      |> then(&Regex.replace(~r/\bsource="[^"]*"/, &1, "source=\"#{new_source}\"", global: false))
      |> then(fn c ->
        case new_target do
          nil -> c
          t -> Regex.replace(~r/\btarget="[^"]*"/, c, "target=\"#{t}\"", global: false)
        end
      end)

    doc = Commonplace.Document.Diff.apply_diff(doc, content, new_content)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStoreClient.create_chained_commit(CommitStoreClient, pr_uuid, update)
  end

  defp flip_trust_strict do
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
  end

  @not_readable_msg "cannot preview: source or target not readable"

  describe "7.3b preview guard" do
    test "(a) FOREIGN-SOURCE EXFILTRATION: refresh on a PR stamped with an unreadable gated doc is refused; no text leaks",
         %{signing_context: ctx} do
      a_uuid = create_leaf_doc("original content")
      {:ok, b_uuid} = CommandRouter.fork(a_uuid)
      {:ok, _} = CommandRouter.write(b_uuid, "edited in the fork")
      pr_uuid = open_pr(ctx, a_uuid, b_uuid)

      # The foreign gated doc + a fork of it. Stamping BOTH endpoints
      # to the F/F' pair means the ancestry re-check PASSES (they
      # genuinely share lineage), so the refusal below is proven to
      # come from the READ GATE, not ancestry.
      foreign_uuid = create_gated_doc(@secret)
      {:ok, foreign_fork} = CommandRouter.fork(foreign_uuid)

      stamp_pr_endpoints(pr_uuid, foreign_uuid, foreign_fork)

      content_before = pr_doc_content(pr_uuid)

      # Only now flip to strict — under the permissive default,
      # reader_authorized? short-circuits true for everyone.
      flip_trust_strict()

      refresh_context = %{view_uuid: pr_uuid, signing_context: ctx, source: "test"}

      assert {:error, @not_readable_msg} =
               ViewActionDispatch.dispatch("pr_refresh_preview", refresh_context)

      # The PR doc took NO write from the refused refresh — preview
      # section (and everything else) byte-identical.
      content_after = pr_doc_content(pr_uuid)
      assert content_after == content_before

      # And none of the foreign doc's text appears anywhere in it.
      refute content_after =~ @secret
      refute content_after =~ "stranger-identity"
    end

    test "(b) ANCESTRY RE-CHECK: refresh on a PR stamped with an unrelated-but-readable source is refused",
         %{signing_context: ctx} do
      a_uuid = create_leaf_doc("original content")
      {:ok, b_uuid} = CommandRouter.fork(a_uuid)
      {:ok, _} = CommandRouter.write(b_uuid, "edited in the fork")
      pr_uuid = open_pr(ctx, a_uuid, b_uuid)

      # A perfectly readable (public) doc with NO shared lineage with A.
      unrelated_uuid = create_leaf_doc("unrelated public text")
      stamp_pr_endpoints(pr_uuid, unrelated_uuid, nil)

      content_before = pr_doc_content(pr_uuid)

      refresh_context = %{view_uuid: pr_uuid, signing_context: ctx, source: "test"}

      assert {:error,
              "cannot preview: no common ancestor — source and target are not fork-related"} =
               ViewActionDispatch.dispatch("pr_refresh_preview", refresh_context)

      content_after = pr_doc_content(pr_uuid)
      assert content_after == content_before
      refute content_after =~ "unrelated public text"
    end

    test "(c) pr_accept on a PR whose source was swapped to an unreadable foreign uuid is refused BEFORE merge",
         %{signing_context: ctx} do
      a_uuid = create_leaf_doc("original content")
      {:ok, b_uuid} = CommandRouter.fork(a_uuid)
      {:ok, _} = CommandRouter.write(b_uuid, "edited in the fork")
      pr_uuid = open_pr(ctx, a_uuid, b_uuid)

      # Refresh legitimately first, so the PR carries a real committed
      # preview — proving the guard fires even on a
      # would-otherwise-look-fresh PR.
      refresh_context = %{view_uuid: pr_uuid, signing_context: ctx, source: "test"}

      {:ok, :tree_mutation, _} =
        ViewActionDispatch.dispatch("pr_refresh_preview", refresh_context)

      foreign_uuid = create_gated_doc(@secret)
      {:ok, foreign_fork} = CommandRouter.fork(foreign_uuid)
      stamp_pr_endpoints(pr_uuid, foreign_uuid, foreign_fork)

      foreign_fork_before = doc_content(foreign_fork)
      content_before = pr_doc_content(pr_uuid)

      flip_trust_strict()

      accept_context = %{view_uuid: pr_uuid, signing_context: ctx, source: "test"}

      # §6 REORDER (cp-plan #8403): authorization now runs BEFORE the
      # preview read-gate. Under strict trust this acceptor is not a
      # trusted writer of the (swapped) target, so accept refuses at
      # AUTHZ — which is a STRICTLY STRONGER outcome for the exfiltration
      # threat than the read-gate: an unauthorized invoker never reaches
      # derive_preview at all, so no scratch fork, no projection, no write
      # of the foreign source's text can happen. (The preview read-gate
      # still fires directly on the refresh path — tests (a)/(b) above —
      # and remains the accept-path defense for an AUTHORIZED target-
      # writer who stamps an unreadable foreign source.) The invariants
      # below are the real proof either way: no merge, no exfiltration.
      assert {:error, "you are not authorized to accept into the target"} =
               ViewActionDispatch.dispatch("pr_accept", accept_context)

      # Refused BEFORE merge: the real original target untouched, the
      # stamped foreign-fork target untouched, PR doc unwritten and
      # still open, no foreign text anywhere.
      assert doc_content(a_uuid) == "original content"
      assert doc_content(foreign_fork) == foreign_fork_before

      content_after = pr_doc_content(pr_uuid)
      assert content_after == content_before
      assert content_after =~ ~s(status="open")
      refute content_after =~ @secret
    end
  end
end

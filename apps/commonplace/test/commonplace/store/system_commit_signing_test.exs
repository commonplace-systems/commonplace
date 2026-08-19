defmodule Commonplace.Store.SystemCommitSigningTest do
  @moduledoc """
  CX-tdkq.24 (phase 2.5): system-minted commits — snapshots and merges —
  are node-signed so strict mode accepts them.

  Without a user SigningContext and without a global SecretStore key,
  these commits were previously unsigned. Now they carry the workspace
  node identity's signature. Regular user commits are unaffected (still
  unsigned absent a key / context) — only the system kinds get the node
  fallback.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing}
  alias Commonplace.Store.{Commit, CommitStore, SecretStore}
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_syscommit_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    old = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    name = :"syscommit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})

    on_exit(fn ->
      Application.put_env(:commonplace, :data_dir, old || "tmp/test_data")

      File.rm_rf!(dir)
    end)

    {:ok, node_ctx} = NodeIdentity.signing_context()
    %{store: name, dir: dir, node_ctx: node_ctx}
  end

  defp text_doc(s) do
    doc = Doc.new(client_id: 1)
    {doc, _} = Doc.get_or_create_type(doc, "t", :text)
    doc = Text.insert(doc, "t", 0, s)
    Encoding.encode_update(doc)
  end

  test "create_snapshot_commit is node-signed", %{store: store, node_ctx: ctx} do
    uuid = "snap-#{:rand.uniform(1_000_000)}"
    CommitStore.create_commit(store, uuid, text_doc("abc"), nil)

    {:ok, snap} = CommitStore.snapshot(store, uuid)

    assert snap.metadata.kind == :snapshot
    assert snap.signature != nil
    assert :ok = Signing.verify_commit(snap, ctx.public_key)

    {:ok, node_id} = NodeIdentity.identity()
    assert {:ok, ^node_id, _fp} = Signing.parse_signer_id(snap.signer_id)
  end

  test "regular user commits stay unsigned when no key/context (unchanged)",
       %{store: store} do
    uuid = "reg-#{:rand.uniform(1_000_000)}"
    commit = CommitStore.create_commit(store, uuid, text_doc("plain"), nil)
    assert commit.signature == nil
    assert commit.signer_id == nil
  end

  test "node-signing does not change the snapshot's content-address id",
       %{store: store} do
    # The id is computed from content only (signature excluded). A
    # node-signed snapshot has the same id as the unsigned one would.
    uuid = "snapid-#{:rand.uniform(1_000_000)}"
    CommitStore.create_commit(store, uuid, text_doc("xyz"), nil)
    {:ok, snap} = CommitStore.snapshot(store, uuid)

    recomputed = Commit.verify_id(snap)
    assert recomputed == :ok
  end

  test "a merge commit written via write_prebuilt_commit_cas is node-signed",
       %{store: store, node_ctx: ctx} do
    uuid = "merge-#{:rand.uniform(1_000_000)}"

    {:ok, _g} = CommitStore.ensure_genesis(store, uuid)
    CommitStore.create_chained_commit(store, uuid, text_doc("base"), %{kind: :regular})
    {:ok, snap} = CommitStore.snapshot(store, uuid)

    # Build a sibling off the snapshot and a local head, then converge.
    {:ok, c_doc} = Encoding.apply_update(Doc.new(), snap.update)
    c_update = Encoding.encode_update(c_doc)

    doc_l = Doc.new(client_id: 2)
    {doc_l, _} = Doc.get_or_create_type(doc_l, "t", :text)
    {:ok, doc_l} = Encoding.apply_update(doc_l, c_update)
    doc_l = Text.insert(doc_l, "t", 0, "L")

    CommitStore.create_chained_commit(store, uuid, Encoding.encode_update(doc_l), %{
      kind: :regular
    })

    doc_r = Doc.new(client_id: 3)
    {doc_r, _} = Doc.get_or_create_type(doc_r, "t", :text)
    {:ok, doc_r} = Encoding.apply_update(doc_r, c_update)
    doc_r = Text.insert(doc_r, "t", 3, "R")

    r_commit =
      Commit.new(uuid, Encoding.encode_update(doc_r), snap.id, %{
        kind: :regular,
        snapshot_parent: snap.id
      })

    :ok = CommitStore.import_commit(store, r_commit)

    assert {:ok, :merged, merge} = Commonplace.SiblingMerger.maybe_merge_siblings(store, uuid)
    assert merge.metadata.kind == :merge
    assert merge.signature != nil
    assert :ok = Signing.verify_commit(merge, ctx.public_key)
  end

  test "snapshot in a keygen'd workspace is node-signed, not global-signed",
       %{store: store} do
    # CX-tdkq.25: a snapshot is a SYSTEM action, not a human one — even
    # when a global user key is configured (the keygen'd-workspace
    # scenario), system kinds must carry NODE attribution, not the
    # human's.
    {global_pub, global_priv} = Signing.generate_keypair()
    SecretStore.set("signing_key:default", Base.encode64(global_priv))
    SecretStore.set("signing_pub:default", Base.encode64(global_pub))
    SecretStore.set("signing_identity", "human-uuid")

    on_exit(fn ->
      SecretStore.delete("signing_key:default")
      SecretStore.delete("signing_pub:default")
      SecretStore.delete("signing_identity")
    end)

    # Mint a snapshot through the normal path (no explicit signing_context).
    uuid = "keygen-snap-#{:rand.uniform(1_000_000)}"
    CommitStore.create_commit(store, uuid, text_doc("abc"), nil)
    {:ok, snapshot} = CommitStore.snapshot(store, uuid)

    {:ok, node_identity} = NodeIdentity.identity()

    assert snapshot.signer_id =~ node_identity,
           "system commit must carry NODE attribution, got #{snapshot.signer_id}"

    refute snapshot.signer_id =~ "human-uuid"
  end

  test "the node-signed snapshot is accepted by Gate B in strict mode",
       %{store: store} do
    # End-to-end deployability: a node-signed snapshot does NOT brick a
    # code doc's executability under strict mode.
    source = """
    defmodule Commonplace.UserCode.SysSign do
      def compute(_raw, _ctx), do: :ok
    end
    """

    uuid = "code-#{:rand.uniform(1_000_000)}"
    {:ok, node_ctx} = NodeIdentity.signing_context()

    doc = Doc.new(client_id: 1)
    doc = Commonplace.Document.ContentType.create(doc, :text, "_s.ex")
    doc = Commonplace.Document.ContentType.insert_text(doc, 0, source)

    CommitStore.create_chained_commit(store, uuid, Encoding.encode_update(doc), %{kind: :regular},
      signing_context: node_ctx
    )

    {:ok, _snap} = CommitStore.snapshot(store, uuid)

    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    on_exit(fn -> Application.delete_env(:commonplace, :trust) end)

    # Both the source commit and the snapshot are node-signed; node is
    # auto-trusted; the contributor walk passes.
    assert :ok = Commonplace.Trust.authorized_to_execute?(store, uuid)
  end
end

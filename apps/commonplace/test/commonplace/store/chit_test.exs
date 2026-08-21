defmodule Commonplace.Store.ChitTest do
  @moduledoc """
  The Chit object type end to end: CAS round-trip, dedup by construction
  (signature outside the cid), the store's forged-cid refusal, the
  branch-ref reflog-of-heads, the `commit -m` mint, verified export at a
  chit's pin, and the F5 determinism proof.

  async: false ON PURPOSE — the mint path leans on the reflog
  checkpoint's idempotency cursor (CX-71ej), which lives in GLOBAL named
  ETS tables shared with every other test in the VM. Other reflog suites
  call `Snapshot.clear_cursor/0` mid-test; a concurrent clear between
  two mints here would turn the determinism assertion into a flake.
  Every equality/dedup assertion carries its refuting arm.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Document.ContentType
  alias Commonplace.GitBridge.Exporter
  alias Commonplace.Store.{Chit, ChitBranchRef, ChitMint, CommitStore, CommitStoreClient}
  alias Commonplace.Tree.{DocBuilder, Schema}

  setup do
    store_dir = Path.join(System.tmp_dir!(), "cp_chit_store_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(store_dir)
    store_name = :"chit_store_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: store_dir, name: store_name})

    on_exit(fn -> File.rm_rf!(store_dir) end)

    %{store: store_name}
  end

  # --- helpers ---

  defp sha(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term))

  defp text_update(name, content) do
    Yelixer.Doc.new()
    |> ContentType.create(:text, name)
    |> ContentType.insert_text(0, content)
    |> Yelixer.Encoding.encode_update()
  end

  defp create_text(store, uuid, name, content) do
    CommitStore.create_commit(store, uuid, text_update(name, content), nil)
  end

  defp edit_text(store, uuid, at, insert) do
    {:ok, doc} = DocBuilder.reconstruct_doc(store, uuid, mint: false)
    doc = ContentType.insert_text(doc, at, insert)
    CommitStoreClient.create_chained_commit(store, uuid, Yelixer.Encoding.encode_update(doc))
  end

  defp signed_ctx do
    {pub, priv} = Commonplace.Crypto.Signing.generate_keypair()

    %Commonplace.Crypto.SigningContext{
      identity_uuid: "alice-uuid",
      private_key: priv,
      public_key: pub
    }
  end

  # A small real tree: root/{a.txt, b.txt, sub/{c.txt}}. Returns the
  # uuids the tests pin against.
  defp build_tree(store) do
    a_uuid = UUID.uuid4()
    b_uuid = UUID.uuid4()
    c_uuid = UUID.uuid4()
    sub_uuid = UUID.uuid4()
    root_uuid = UUID.uuid4()

    create_text(store, a_uuid, "a.txt", "alpha")
    create_text(store, b_uuid, "b.txt", "beta")
    create_text(store, c_uuid, "c.txt", "gamma")

    sub = Schema.new_schema() |> Schema.add_file("c.txt", c_uuid)
    CommitStore.create_commit(store, sub_uuid, Yelixer.Encoding.encode_update(sub), nil)

    root =
      Schema.new_schema()
      |> Schema.add_file("a.txt", a_uuid)
      |> Schema.add_file("b.txt", b_uuid)
      |> Schema.add_directory("sub", sub_uuid)

    CommitStore.create_commit(store, root_uuid, Yelixer.Encoding.encode_update(root), nil)

    %{root: root_uuid, a: a_uuid, b: b_uuid, c: c_uuid, sub: sub_uuid}
  end

  # --- [1] CAS round-trip ---

  test "CAS round-trip: store_chit then get_chit yields the identical struct", %{store: store} do
    chit = Chit.new(%{"u-a" => sha("a")}, [], "alice@feedface", "first light", 1_000)

    assert Chit.verify_cid(chit) == :ok
    assert {:ok, cid} = CommitStoreClient.store_chit(store, chit)
    assert cid == chit.cid
    assert {:ok, ^chit} = CommitStoreClient.get_chit(store, cid)

    # refuting arm: a cid never stored reads back :none
    assert CommitStoreClient.get_chit(store, sha("never stored")) == :none
  end

  # --- [2] dedup both arms ---

  test "same artifact fields dedup to the same cid; signature stays outside it", %{store: _} do
    pin = %{"u-a" => sha("a"), "u-b" => sha("b")}

    c1 = Chit.new(pin, [], "alice", "moment", 42)
    c2 = Chit.new(pin, [], "alice", "moment", 42)
    assert c1.cid == c2.cid

    # signed vs unsigned: same cid, differing envelopes — the dedup
    # property the two-layer split exists for.
    ctx = signed_ctx()
    signed = Chit.sign(c2, ctx)
    assert signed.cid == c1.cid
    assert signed.signature != nil
    assert c1.signature == nil
    assert signed.signer_id != nil
    assert Chit.verify_signature(signed, ctx.public_key) == :ok
    # signature refuting arm: wrong key does not verify
    {other_pub, _} = Commonplace.Crypto.Signing.generate_keypair()
    assert Chit.verify_signature(signed, other_pub) == {:error, :invalid_signature}
    assert Chit.verify_signature(c1, ctx.public_key) == {:error, :unsigned}

    # refuting arms: every artifact field moves the cid
    refute Chit.new(pin, [], "alice", "other message", 42).cid == c1.cid
    refute Chit.new(Map.put(pin, "u-c", sha("c")), [], "alice", "moment", 42).cid == c1.cid
    refute Chit.new(pin, [c1.cid], "alice", "moment", 42).cid == c1.cid
    refute Chit.new(pin, [], "bob", "moment", 42).cid == c1.cid
    refute Chit.new(pin, [], "alice", "moment", 43).cid == c1.cid
  end

  # --- [3] the store refuses a forged cid ---

  test "store_chit refuses a forged cid, and the refusal prevents the write", %{store: store} do
    chit = Chit.new(%{"u-a" => sha("a")}, [], nil, "honest", 7)

    # forged id arm
    forged = %{chit | cid: sha("forged")}

    assert {:error, {:cid_mismatch, _computed, _claimed}} =
             CommitStoreClient.store_chit(store, forged)

    assert CommitStoreClient.get_chit(store, forged.cid) == :none

    # tampered field arm: valid-looking cid, content no longer matches
    tampered = %{chit | message: "evil"}
    assert {:error, {:cid_mismatch, _, _}} = CommitStoreClient.store_chit(store, tampered)
    assert CommitStoreClient.get_chit(store, tampered.cid) == :none

    # green-on-known-good arm: the untampered chit still stores
    assert {:ok, _} = CommitStoreClient.store_chit(store, chit)
    assert {:ok, ^chit} = CommitStoreClient.get_chit(store, chit.cid)
  end

  # --- [4] branch-ref history ---

  test "branch ref: head follows advances, history is the reflog-of-heads", %{store: store} do
    branch = UUID.uuid4()
    [a, b, c] = [sha("A"), sha("B"), sha("C")]

    assert ChitBranchRef.head(store, branch) == :none
    assert ChitBranchRef.history(store, branch) == []

    assert {:ok, _} = ChitBranchRef.advance(store, branch, a)
    log_after_one = CommitStoreClient.commit_log(store, branch, limit: 10)
    assert {:ok, ^a} = ChitBranchRef.head(store, branch)

    assert {:ok, _} = ChitBranchRef.advance(store, branch, b)
    assert {:ok, _} = ChitBranchRef.advance(store, branch, c)

    assert {:ok, ^c} = ChitBranchRef.head(store, branch)
    # documented order: oldest first — the branch's forward narrative
    assert ChitBranchRef.history(store, branch) == [a, b, c]

    # each advance is a chained commit: the commit_log grew by exactly
    # one per advance (genesis stamp + 3 advances = 4)
    log_after_three = CommitStoreClient.commit_log(store, branch, limit: 10)
    assert length(log_after_three) == length(log_after_one) + 2
    assert length(log_after_three) == 4
  end

  # --- [5] commit -m end-to-end ---

  test "ChitMint.commit pins real rows, chains parents, advances the branch", %{store: store} do
    tree = build_tree(store)
    branch = UUID.uuid4()

    {:ok, a_head} = CommitStoreClient.latest_commit(store, tree.a)

    assert {:ok, chit1} = ChitMint.commit(store, tree.root, branch, "first checkpoint")
    assert chit1.parents == []
    assert chit1.message == "first checkpoint"
    assert is_integer(chit1.authored_at)
    assert Chit.verify_cid(chit1) == :ok

    # the pin covers the three files, both directory schemas, and the
    # checkpoint anchor — and every pair is a REAL row in the store
    assert map_size(chit1.tree_pin) == 6
    assert chit1.tree_pin[tree.a] == a_head.id
    assert Map.has_key?(chit1.tree_pin, tree.sub)
    assert Map.has_key?(chit1.tree_pin, tree.root)

    for {uuid, commit_id} <- chit1.tree_pin do
      assert CommitStoreClient.doc_has_commit?(store, uuid, commit_id),
             "pinned pair #{uuid} => #{Base.encode16(commit_id, case: :lower)} is not a real row"
    end

    # the chit itself is retrievable, and the branch advanced to it
    assert {:ok, ^chit1} = CommitStoreClient.get_chit(store, chit1.cid)
    assert {:ok, chit1_cid} = ChitBranchRef.head(store, branch)
    assert chit1_cid == chit1.cid

    # second commit after a real edit: parents chain, pin moves
    edited = edit_text(store, tree.a, 5, " edited")
    assert {:ok, chit2} = ChitMint.commit(store, tree.root, branch, "second checkpoint")

    assert chit2.parents == [chit1.cid]
    refute chit2.cid == chit1.cid
    assert chit2.tree_pin[tree.a] == edited.id
    assert {:ok, chit2_cid} = ChitBranchRef.head(store, branch)
    assert chit2_cid == chit2.cid
    assert ChitBranchRef.history(store, branch) == [chit1.cid, chit2.cid]
  end

  # --- [6] verifiable export through [6] at the chit's pin ---

  test "the chit's tree_pin drives a verified export of the pinned moment", %{store: store} do
    repo_dir = Path.join(System.tmp_dir!(), "cp_chit_repo_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(repo_dir)
    on_exit(fn -> File.rm_rf!(repo_dir) end)

    tree = build_tree(store)
    branch = UUID.uuid4()
    assert {:ok, chit} = ChitMint.commit(store, tree.root, branch, "export me")

    # edit AFTER the mint, so pinned content and head content diverge —
    # the refuting arm that proves the pin actually pins
    edit_text(store, tree.a, 5, " drifted")

    assert {:ok, result} = Exporter.export(tree.root, repo_dir, store, %{}, chit.tree_pin)

    # every manifest entry carries a verdict
    assert map_size(result.manifest) == 3

    for {rel, entry} <- result.manifest do
      assert Map.has_key?(entry, :verdict), "no verdict on #{rel}"
    end

    # pinned bytes, not head bytes
    assert File.read!(Path.join(repo_dir, "a.txt")) == "alpha"
    assert File.read!(Path.join(repo_dir, "sub/c.txt")) == "gamma"

    # refuting arm: the unpinned export sees the drifted head
    File.rm_rf!(repo_dir)
    File.mkdir_p!(repo_dir)
    assert {:ok, _} = Exporter.export(tree.root, repo_dir, store)
    assert File.read!(Path.join(repo_dir, "a.txt")) == "alpha drifted"
  end

  # --- [7] F5 determinism ---

  test "two mints of an unchanged moment produce the SAME cid", %{store: store} do
    tree = build_tree(store)

    # Two INDEPENDENT minters of the same moment: separate fresh branch
    # refs (both parents == []), no store change between the mints. On
    # the SAME branch a second mint necessarily differs — its parent is
    # the first chit, and parents are artifact fields — so independent
    # branches are the shape the dedup-by-construction claim is about.
    branch_a = UUID.uuid4()
    branch_b = UUID.uuid4()

    assert {:ok, chit_a} = ChitMint.commit(store, tree.root, branch_a, "moment")
    assert {:ok, chit_b} = ChitMint.commit(store, tree.root, branch_b, "moment")

    # the load-bearing determinism proof: cursor-idempotent checkpoint
    # (CX-71ej) + artifact-derived authored_at ⇒ byte-identical artifact
    assert chit_b.authored_at == chit_a.authored_at
    assert chit_b.tree_pin == chit_a.tree_pin
    assert chit_b.cid == chit_a.cid

    # refuting arm 1: same branch, unchanged tree — parents differ, so
    # the cid differs (and that is correct, not a determinism failure)
    assert {:ok, chit_a2} = ChitMint.commit(store, tree.root, branch_a, "moment")
    assert chit_a2.parents == [chit_a.cid]
    refute chit_a2.cid == chit_a.cid

    # refuting arm 2: a store change between mints moves the pin ⇒ cid
    edit_text(store, tree.b, 4, " moved")
    assert {:ok, chit_c} = ChitMint.commit(store, tree.root, UUID.uuid4(), "moment")
    refute chit_c.tree_pin == chit_a.tree_pin
    refute chit_c.cid == chit_a.cid
  end
end

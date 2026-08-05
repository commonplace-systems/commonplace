defmodule Commonplace.Store.NamespaceTest do
  @moduledoc """
  Tests for Commonplace.Store.Namespace — the namespace-membership walker.

  Walks from a given snapshot_parent commit back to the namespace root
  (a :genesis or :snapshot) and aggregates clientIDs observed along the
  way. The validator uses this set to decide whether a regular commit's
  clientIDs are allowed in the namespace.
  """
  use ExUnit.Case

  alias Commonplace.Store.{Commit, CommitStore, Namespace}

  setup do
    dir = Path.join(System.tmp_dir!(), "namespace_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"namespace_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  defp update_from(client_id, content) do
    doc = Yelixer.Doc.new(client_id: client_id)
    {doc, _} = Yelixer.Doc.get_or_create_type(doc, "t", :text)
    doc = Yelixer.Types.Text.insert(doc, "t", 0, content)
    Yelixer.Encoding.encode_update(doc)
  end

  defp regular_commit(store, doc_uuid, update, parent_id, snapshot_parent) do
    metadata = %{kind: :regular, snapshot_parent: snapshot_parent}
    CommitStore.create_commit(store, doc_uuid, update, parent_id, metadata)
  end

  describe "namespace_client_ids/2" do
    test "genesis-only chain yields an empty set", %{store: store} do
      uuid = "ns-empty"
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)

      assert {:ok, set} = Namespace.namespace_client_ids(store, genesis.id)
      assert MapSet.size(set) == 0
    end

    test "single regular commit contributes its clientID", %{store: store} do
      uuid = "ns-one"
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)

      c1 = regular_commit(store, uuid, update_from(7, "hi"), genesis.id, genesis.id)

      assert {:ok, set} = Namespace.namespace_client_ids(store, c1.id)
      assert set == MapSet.new([7])
    end

    test "multiple regular commits accumulate clientIDs", %{store: store} do
      uuid = "ns-acc"
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)

      c1 = regular_commit(store, uuid, update_from(1, "a"), genesis.id, genesis.id)
      c2 = regular_commit(store, uuid, update_from(2, "b"), c1.id, genesis.id)
      c3 = regular_commit(store, uuid, update_from(3, "c"), c2.id, genesis.id)

      assert {:ok, set} = Namespace.namespace_client_ids(store, c3.id)
      assert set == MapSet.new([1, 2, 3])
    end

    test "walk stops at genesis (does not cross over)", %{store: store} do
      uuid = "ns-stop-genesis"
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)

      c1 = regular_commit(store, uuid, update_from(5, "x"), genesis.id, genesis.id)

      # Walking from genesis itself should yield empty — the genesis is the root.
      assert {:ok, set} = Namespace.namespace_client_ids(store, genesis.id)
      assert MapSet.size(set) == 0
      # Sanity: from c1 we see 5.
      assert {:ok, set1} = Namespace.namespace_client_ids(store, c1.id)
      assert set1 == MapSet.new([5])
    end

    test "unknown commit id yields an empty set", %{store: store} do
      assert {:ok, set} = Namespace.namespace_client_ids(store, <<0::256>>)
      assert MapSet.size(set) == 0
    end
  end

  describe "validate_regular/3 dispatch on snapshot_parent claims (CX-hqko)" do
    # CX-hqko: validation judges CLAIMS, not ABSENCES. A :regular commit
    # whose metadata has NO :snapshot_parent key makes no claim about its
    # epoch and is accepted here (it remains subject to the separate
    # WHO/trust gates). A commit that DOES carry the key is held to that
    # claim completely: present-but-unusable is a malformed claim and
    # still rejects, and present-and-binary is validated by the existing
    # strict ancestry walk.

    test "absent snapshot_parent key -> :ok (no epoch claim, nothing to validate)", %{
      store: store
    } do
      uuid = "ns-absent"
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)

      # No :snapshot_parent key at all — e.g. an honest modernizer
      # chaining kinded metadata onto a legacy-headed doc.
      commit = Commit.new(uuid, update_from(1, "a"), genesis.id, %{kind: :regular, some_key: "x"})

      assert :ok = Namespace.validate_commit(store, commit)
    end

    test "present-but-nil snapshot_parent -> {:error, :missing_snapshot_parent} (malformed claim)",
         %{store: store} do
      uuid = "ns-present-nil"
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)

      commit = Commit.new(uuid, update_from(1, "a"), genesis.id, %{
        kind: :regular,
        snapshot_parent: nil
      })

      assert {:error, :missing_snapshot_parent} = Namespace.validate_commit(store, commit)
    end

    test "present, binary, resolvable snapshot_parent -> :ok (existing strict path unchanged)",
         %{store: store} do
      uuid = "ns-present-binary-ok"
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)

      commit = Commit.new(uuid, update_from(1, "a"), genesis.id, %{
        kind: :regular,
        snapshot_parent: genesis.id
      })

      assert :ok = Namespace.validate_commit(store, commit)
    end

    test "present, binary, unresolvable reference -> {:error, {:unknown_reference, _}} (still strict)",
         %{store: store} do
      uuid = "ns-present-binary-unresolvable"
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)

      # Seed the namespace with clientID 1 only.
      c1 =
        CommitStore.create_commit(store, uuid, update_from(1, "a"), genesis.id, %{
          kind: :regular,
          snapshot_parent: genesis.id
        })

      # Build an update whose reference clientID (999) is outside the
      # namespace {1} — the strict path must still reject this even
      # though snapshot_parent is present and binary.
      doc_ref = Yelixer.Doc.new(client_id: 999)
      {doc_ref, _} = Yelixer.Doc.get_or_create_type(doc_ref, "t", :text)
      doc_ref = Yelixer.Types.Text.insert(doc_ref, "t", 0, "ref")
      base = Yelixer.Encoding.encode_update(doc_ref)

      doc_auth = Yelixer.Doc.new(client_id: 42)
      {doc_auth, _} = Yelixer.Doc.get_or_create_type(doc_auth, "t", :text)
      {:ok, doc_auth} = Yelixer.Encoding.apply_update(doc_auth, base)
      doc_auth = Yelixer.Types.Text.insert(doc_auth, "t", 3, "X")
      base_sv = Yelixer.BlockStore.state_vector(doc_ref.store)
      referencing_update = Yelixer.Encoding.encode_diff(doc_auth, base_sv)

      commit = Commit.new(uuid, referencing_update, c1.id, %{
        kind: :regular,
        snapshot_parent: genesis.id
      })

      assert {:error, {:unknown_reference, ids}} = Namespace.validate_commit(store, commit)
      assert 999 in ids
    end
  end

  describe "clientID_in_namespace?/3" do
    test "returns true for a clientID present in the walk", %{store: store} do
      uuid = "ns-in"
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)
      c1 = regular_commit(store, uuid, update_from(11, "hi"), genesis.id, genesis.id)

      assert Namespace.clientID_in_namespace?(store, c1.id, 11)
      refute Namespace.clientID_in_namespace?(store, c1.id, 99)
    end

    test "returns false for any clientID when namespace is empty", %{store: store} do
      uuid = "ns-empty-bool"
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)

      refute Namespace.clientID_in_namespace?(store, genesis.id, 1)
      refute Namespace.clientID_in_namespace?(store, genesis.id, 42)
    end
  end
end

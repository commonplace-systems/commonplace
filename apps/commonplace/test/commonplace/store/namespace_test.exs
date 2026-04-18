defmodule Commonplace.Store.NamespaceTest do
  @moduledoc """
  Tests for Commonplace.Store.Namespace — the namespace-membership walker.

  Walks from a given snapshot_parent commit back to the namespace root
  (a :genesis or :snapshot) and aggregates clientIDs observed along the
  way. The validator uses this set to decide whether a regular commit's
  clientIDs are allowed in the namespace.
  """
  use ExUnit.Case

  alias Commonplace.Store.{CommitStore, Namespace}

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

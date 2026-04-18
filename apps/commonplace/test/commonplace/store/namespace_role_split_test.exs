defmodule Commonplace.Store.NamespaceRoleSplitTest do
  @moduledoc """
  CX-fbs6: role-split namespace validator.

  Namespace semantics are restated as:
  - `namespace` = initial snapshot clients ∪ authors-since (growing set,
    not closed at snapshot time).
  - **Reference clients** (origin, right_origin, `{:id, _}` parent,
    delete_set targets) MUST be in the cumulative namespace — they
    point at existing items and must resolve.
  - **Authorship clients** (clientIDs owning NEW items inserted by this
    commit) are NOT subject to the subset check — they EXTEND the
    namespace when the commit lands.

  The CX-ch5 validator conflated the two; this bead separates them so
  translated cross-epoch commits (CX-fefz / CX-fdjh / CX-dx22) whose
  authorship comes from peers new to the target namespace can import
  cleanly, while commits that genuinely reference unresolvable items
  are still rejected.
  """
  use ExUnit.Case

  alias Commonplace.Store.{Commit, CommitStore}
  alias Yelixer.{BlockStore, Doc, Encoding}
  alias Yelixer.Types.Text

  setup do
    dir = Path.join(System.tmp_dir!(), "ns_rs_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"ns_rs_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  defp seed_client1(store, uuid) do
    {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)

    c1 =
      CommitStore.create_commit(
        store,
        uuid,
        insert_bytes(1, "abc"),
        genesis.id,
        %{kind: :regular, snapshot_parent: genesis.id}
      )

    {genesis, c1}
  end

  defp insert_bytes(client_id, content) do
    doc = Doc.new(client_id: client_id)
    {doc, _} = Doc.get_or_create_type(doc, "t", :text)
    doc = Text.insert(doc, "t", 0, content)
    Encoding.encode_update(doc)
  end

  # -------------------- Authorship extends namespace --------------------

  describe "authorship-only commit from a new clientID extends the namespace" do
    test "accepts a commit whose new clientID is authorship-only",
         %{store: store} do
      uuid = "cx-fbs6-auth-only"
      {genesis, c1} = seed_client1(store, uuid)

      # Namespace chain at c1 = {1}. A commit from client 2 with no
      # refs (pure insert at pos 0 of its own fresh doc) has
      # authorship={2}, reference=∅. Under role-split, refs subset
      # check passes (empty ⊆ {1}); client 2 joins the namespace.
      c2 =
        Commit.new(
          uuid,
          insert_bytes(2, "Z"),
          c1.id,
          %{kind: :regular, snapshot_parent: genesis.id}
        )

      assert :ok = CommitStore.import_commit(store, c2)
    end

    test "a follow-up commit referencing the newly-joined clientID is accepted",
         %{store: store} do
      uuid = "cx-fbs6-auth-chain"
      {genesis, c1} = seed_client1(store, uuid)

      # Client 2 joins via authorship-only commit.
      c2 =
        Commit.new(
          uuid,
          insert_bytes(2, "Z"),
          c1.id,
          %{kind: :regular, snapshot_parent: genesis.id}
        )

      :ok = CommitStore.import_commit(store, c2)

      # Client 3 references client 2's content (inserts AFTER Z).
      # authorship={3}, reference={2}. Since client 2 joined at c2,
      # namespace at c2 = {1, 2}; the ref subset check passes.
      doc_c2 = Doc.new(client_id: 3)
      {doc_c2, _} = Doc.get_or_create_type(doc_c2, "t", :text)
      {:ok, doc_c2} = Encoding.apply_update(doc_c2, insert_bytes(2, "Z"))
      doc_c2 = Text.insert(doc_c2, "t", 1, "W")

      doc2_only = Doc.new(client_id: 2)
      {doc2_only, _} = Doc.get_or_create_type(doc2_only, "t", :text)
      doc2_only = Text.insert(doc2_only, "t", 0, "Z")
      base_sv = BlockStore.state_vector(doc2_only.store)

      c3_update = Encoding.encode_diff(doc_c2, base_sv)

      c3 =
        Commit.new(
          uuid,
          c3_update,
          c2.id,
          %{kind: :regular, snapshot_parent: genesis.id}
        )

      assert :ok = CommitStore.import_commit(store, c3)
    end
  end

  # -------------------- Reference rejection --------------------

  describe "reference clientID outside namespace is rejected" do
    test "rejects a commit whose origin refs a client not in namespace",
         %{store: store} do
      uuid = "cx-fbs6-bad-ref"
      {genesis, c1} = seed_client1(store, uuid)

      # Build a doc where client 999 authors "mal", then client 42
      # applies that and inserts "X" after client 999's content.
      # The diff from client 42 alone has authorship={42} and
      # reference={999} (X's origin points at 999's last clock).
      doc999 = Doc.new(client_id: 999)
      {doc999, _} = Doc.get_or_create_type(doc999, "t", :text)
      doc999 = Text.insert(doc999, "t", 0, "mal")
      base = Encoding.encode_update(doc999)

      doc42 = Doc.new(client_id: 42)
      {doc42, _} = Doc.get_or_create_type(doc42, "t", :text)
      {:ok, doc42} = Encoding.apply_update(doc42, base)
      doc42 = Text.insert(doc42, "t", 3, "X")

      sv_after999 = BlockStore.state_vector(doc999.store)
      bad_update = Encoding.encode_diff(doc42, sv_after999)

      # Namespace at c1 = {1}. Commit has reference={999} ⊄ {1}.
      bad =
        Commit.new(
          uuid,
          bad_update,
          c1.id,
          %{kind: :regular, snapshot_parent: genesis.id}
        )

      assert {:error, {:namespace_rejected, {:unknown_reference, outside}}} =
               CommitStore.import_commit(store, bad)

      assert 999 in outside
    end

    test "rejects a commit whose delete_set targets a client not in namespace",
         %{store: store} do
      uuid = "cx-fbs6-bad-delete"
      {genesis, c1} = seed_client1(store, uuid)

      # Build delete-only update: client 5 observes client 777's
      # "nope" content and deletes it. The diff has authorship=∅
      # (no new items) and reference={777} (delete set target).
      doc777 = Doc.new(client_id: 777)
      {doc777, _} = Doc.get_or_create_type(doc777, "t", :text)
      doc777 = Text.insert(doc777, "t", 0, "nope")
      base = Encoding.encode_update(doc777)

      doc5 = Doc.new(client_id: 5)
      {doc5, _} = Doc.get_or_create_type(doc5, "t", :text)
      {:ok, doc5} = Encoding.apply_update(doc5, base)
      doc5 = Text.delete(doc5, "t", 0, 4)

      sv_after777 = BlockStore.state_vector(doc777.store)
      delete_only_update = Encoding.encode_diff(doc5, sv_after777)

      bad =
        Commit.new(
          uuid,
          delete_only_update,
          c1.id,
          %{kind: :regular, snapshot_parent: genesis.id}
        )

      assert {:error, {:namespace_rejected, {:unknown_reference, outside}}} =
               CommitStore.import_commit(store, bad)

      assert 777 in outside
    end

    test "emits [:commonplace, :commit, :rejected, :unknown_reference] telemetry",
         %{store: store} do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {:cx_fbs6_ur, ref},
        [:commonplace, :commit, :rejected, :unknown_reference],
        fn _event, _m, meta, _cfg ->
          send(parent, {:unknown_reference_fired, ref, meta})
        end,
        nil
      )

      uuid = "cx-fbs6-tel"
      {genesis, c1} = seed_client1(store, uuid)

      doc555 = Doc.new(client_id: 555)
      {doc555, _} = Doc.get_or_create_type(doc555, "t", :text)
      doc555 = Text.insert(doc555, "t", 0, "stuff")
      base = Encoding.encode_update(doc555)

      doc11 = Doc.new(client_id: 11)
      {doc11, _} = Doc.get_or_create_type(doc11, "t", :text)
      {:ok, doc11} = Encoding.apply_update(doc11, base)
      doc11 = Text.insert(doc11, "t", 5, "Q")

      sv_after555 = BlockStore.state_vector(doc555.store)
      bad_update = Encoding.encode_diff(doc11, sv_after555)

      bad =
        Commit.new(
          uuid,
          bad_update,
          c1.id,
          %{kind: :regular, snapshot_parent: genesis.id}
        )

      assert {:error, _} = CommitStore.import_commit(store, bad)

      assert_receive {:unknown_reference_fired, ^ref, meta}
      assert meta.commit_id == bad.id
      assert meta.doc_uuid == uuid
      assert 555 in meta.outside

      :telemetry.detach({:cx_fbs6_ur, ref})
    end
  end
end

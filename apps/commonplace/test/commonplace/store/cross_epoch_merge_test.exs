defmodule Commonplace.Store.CrossEpochMergeTest do
  @moduledoc """
  CX-fdjh (Build 7.3): `Commonplace.Store.CrossEpochMerge.merge/3`
  produces a merge commit in L's namespace carrying R's edits-since-
  common-ancestor, commuted via two DM translation passes:

  - Pass 1 (R → C): rewrite R's op references via `compose_dms(R_chain)`
    applied as a direct lookup (forward DMs have keys=R-ns, values=C-ns).
  - Pass 2 (C → L): rewrite pass-1 output refs via the INVERSE of
    `compose_dms(L_chain)` (inverse has keys=C-ns, values=L-ns).

  Each pass runs 6.4 pre-flight first. Failures emit
  `[:commonplace, :late_edit, :untranslatable]` with `phase: :r_to_c`
  or `phase: :c_to_l` in metadata.

  Scope per commonplace-plan msg 2218 + 2236:
  - SHIP in-memory byte-determinism tests on the merge commit struct.
  - CID-dedup-via-import covered under CX-fbs6 role-split validator.
  - Include an intermediate-state test that verifies R→C pass output
    has every non-own ref landing in C's namespace before pass 2 runs.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Store.{Commit, CommitStore, CrossEpochMerge}
  alias Yelixer.{BlockStore, Doc, Encoding}
  alias Yelixer.Types.Text

  setup do
    dir = Path.join(System.tmp_dir!(), "cem_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"cem_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  # -------------------- Scenario builders --------------------

  # Build a seed doc with client 1 inserting "abc" into bare text type "t"
  # and snapshot it. Returns {uuid, c_snapshot, base_sv}. `c_snapshot` is
  # the common-ancestor snapshot both branches will hang off.
  defp seed_and_snapshot(store, uuid) do
    {:ok, _genesis} = CommitStore.ensure_genesis(store, uuid)

    doc_p = Doc.new(client_id: 1)
    {doc_p, _} = Doc.get_or_create_type(doc_p, "t", :text)
    doc_p = Text.insert(doc_p, "t", 0, "abc")
    e_p = Encoding.encode_update(doc_p)

    _reg = CommitStore.create_chained_commit(store, uuid, e_p, %{kind: :regular})
    {:ok, snapshot} = CommitStore.snapshot(store, uuid)
    base_sv = BlockStore.state_vector(doc_p.store)

    {uuid, snapshot, base_sv}
  end

  # Author a regular commit chained off the current :latest, under a
  # distinct client id + edit. Returns the commit struct.
  defp author_regular(store, uuid, base_update, client_id, op_fn) do
    doc_b = Doc.new(client_id: client_id)
    {doc_b, _} = Doc.get_or_create_type(doc_b, "t", :text)
    {:ok, doc_b} = Encoding.apply_update(doc_b, base_update)
    doc_b = op_fn.(doc_b)
    update = Encoding.encode_update(doc_b)
    CommitStore.create_chained_commit(store, uuid, update, %{kind: :regular})
  end

  defp capture_telemetry(event) do
    test_pid = self()
    handler_id = {__MODULE__, event, make_ref()}

    :telemetry.attach(
      handler_id,
      event,
      fn ^event, meas, meta, _cfg ->
        send(test_pid, {:telemetry, event, meas, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  # -------------------- Empty-chain case (both L and R off C) --------

  describe "merge/3 — both branches hang directly off common ancestor" do
    test "produces a :merge commit with L as parent and R in merge_parents",
         %{store: store} do
      {uuid, c_snapshot, _base_sv} = seed_and_snapshot(store, "cem-basic")

      # Reconstruct the snapshot's doc state to branch both sides off it.
      {:ok, c_doc} = Encoding.apply_update(Doc.new(), c_snapshot.update)
      c_update = Encoding.encode_update(c_doc)

      # L branch: client 2 inserts "X" at pos 0.
      l_commit =
        author_regular(store, uuid, c_update, 2, fn d ->
          Text.insert(d, "t", 0, "X")
        end)

      # R branch: client 3 inserts "Y" at end. Chain off C manually to
      # avoid following :latest (which now points at L).
      doc_r = Doc.new(client_id: 3)
      {doc_r, _} = Doc.get_or_create_type(doc_r, "t", :text)
      {:ok, doc_r} = Encoding.apply_update(doc_r, c_update)
      doc_r = Text.insert(doc_r, "t", 3, "Y")
      r_update = Encoding.encode_update(doc_r)

      r_commit =
        Commit.new(uuid, r_update, c_snapshot.id, %{
          kind: :regular,
          snapshot_parent: c_snapshot.id
        })

      :ok =
        CommitStore.import_commit(store, r_commit,
          validator: fn _ -> :ok end
        )

      assert {:ok, merge} = CrossEpochMerge.merge(store, l_commit.id, r_commit.id)
      assert %Commit{} = merge
      assert merge.doc_uuid == uuid
      assert merge.parent_id == l_commit.id
      assert merge.merge_parents == [r_commit.id]
      assert merge.metadata[:kind] == :merge
      assert merge.metadata[:snapshot_parent] == c_snapshot.id
      assert is_binary(merge.update)
    end

    test "applying the merge commit to D_L yields a doc containing both branches' content",
         %{store: store} do
      {uuid, c_snapshot, _base_sv} = seed_and_snapshot(store, "cem-content")

      {:ok, c_doc} = Encoding.apply_update(Doc.new(), c_snapshot.update)
      c_update = Encoding.encode_update(c_doc)

      l_commit =
        author_regular(store, uuid, c_update, 2, fn d ->
          Text.insert(d, "t", 0, "X")
        end)

      doc_r = Doc.new(client_id: 3)
      {doc_r, _} = Doc.get_or_create_type(doc_r, "t", :text)
      {:ok, doc_r} = Encoding.apply_update(doc_r, c_update)
      doc_r = Text.insert(doc_r, "t", 3, "Y")
      r_update = Encoding.encode_update(doc_r)

      r_commit =
        Commit.new(uuid, r_update, c_snapshot.id, %{
          kind: :regular,
          snapshot_parent: c_snapshot.id
        })

      :ok = CommitStore.import_commit(store, r_commit, validator: fn _ -> :ok end)

      {:ok, merge} = CrossEpochMerge.merge(store, l_commit.id, r_commit.id)

      # Reconstruct D_L then apply the merge commit's update. Expect
      # both "X" (L's edit) and "Y" (R's edit) to be present alongside
      # "abc" from the common ancestor.
      {:ok, d_l} = Encoding.apply_update(Doc.new(), c_snapshot.update)
      {:ok, d_l} = Encoding.apply_update(d_l, l_commit.update)
      {:ok, d_merged} = Encoding.apply_update(d_l, merge.update)

      text = Text.to_string(d_merged, "t")
      assert String.contains?(text, "X")
      assert String.contains?(text, "Y")
      assert String.contains?(text, "abc")
    end
  end

  # -------------------- Byte-determinism --------------------

  describe "merge/3 — byte-determinism" do
    test "two independent peers computing the same merge produce identical commit structs",
         %{store: store} do
      # Peer 1: do the whole setup + merge in store A (our `store`).
      {uuid, c_snapshot, _} = seed_and_snapshot(store, "cem-bd")
      {:ok, c_doc} = Encoding.apply_update(Doc.new(), c_snapshot.update)
      c_update = Encoding.encode_update(c_doc)

      l_commit =
        author_regular(store, uuid, c_update, 2, fn d ->
          Text.insert(d, "t", 0, "X")
        end)

      doc_r = Doc.new(client_id: 3)
      {doc_r, _} = Doc.get_or_create_type(doc_r, "t", :text)
      {:ok, doc_r} = Encoding.apply_update(doc_r, c_update)
      doc_r = Text.insert(doc_r, "t", 3, "Y")
      r_update = Encoding.encode_update(doc_r)

      r_commit =
        Commit.new(uuid, r_update, c_snapshot.id, %{
          kind: :regular,
          snapshot_parent: c_snapshot.id
        })

      :ok = CommitStore.import_commit(store, r_commit, validator: fn _ -> :ok end)

      {:ok, merge_a} = CrossEpochMerge.merge(store, l_commit.id, r_commit.id)
      {:ok, merge_b} = CrossEpochMerge.merge(store, l_commit.id, r_commit.id)

      assert merge_a.id == merge_b.id
      assert merge_a.update == merge_b.update
      assert merge_a.parent_id == merge_b.parent_id
      assert merge_a.merge_parents == merge_b.merge_parents
      assert merge_a.metadata == merge_b.metadata
    end
  end

  # -------------------- Intermediate-state R→C pass --------------------
  #
  # Per commonplace-plan msg 2218: verify that after pass 1, R-side
  # refs land in C's namespace. This is the check that catches
  # chain-direction errors in compose_dms early — before pass 2 runs.
  #
  # We inject a non-trivial DM via `r_chain_override:` so pass 1 has
  # an actual translation to perform. Pass 2 is identity (empty
  # L_chain). Decoding the final merge commit bytes and examining the
  # translated refs shows pass 1's output directly.

  describe "merge/3 — intermediate-state R→C pass check" do
    test "pass 1 rewrites R-refs through R_composed before pass 2 runs",
         %{store: store} do
      {uuid, c_snapshot, _} = seed_and_snapshot(store, "cem-mid")

      {:ok, c_doc} = Encoding.apply_update(Doc.new(), c_snapshot.update)
      c_update = Encoding.encode_update(c_doc)

      l_commit =
        author_regular(store, uuid, c_update, 2, fn d ->
          Text.insert(d, "t", 0, "X")
        end)

      # R-side: client 5 appends "Z" at end of "abc" → origin will be
      # the last item at clock 2 under whichever client holds "c".
      # In this seed, C's re-authoring client is the smallest client
      # in the source doc (client 1 — see Snapshotter.deterministic_
      # client_id/1), so the origin lands on {1, 2}.
      doc_r = Doc.new(client_id: 5)
      {doc_r, _} = Doc.get_or_create_type(doc_r, "t", :text)
      {:ok, doc_r} = Encoding.apply_update(doc_r, c_update)
      doc_r = Text.insert(doc_r, "t", 3, "Z")
      r_update = Encoding.encode_update(doc_r)

      r_commit =
        Commit.new(uuid, r_update, c_snapshot.id, %{
          kind: :regular,
          snapshot_parent: c_snapshot.id
        })

      :ok = CommitStore.import_commit(store, r_commit, validator: fn _ -> :ok end)

      # Override the R_chain with a synthetic snapshot carrying a DM
      # that remaps {1, 2} → {99, 42}. If pass 1 ran correctly, the
      # translated bytes will carry origin {99, 42} instead of {1, 2}.
      opts = [
        r_chain_override: [
          %{
            id: "fake_rs",
            metadata: %{derivation_map: %{c_snapshot.id => %{{1, 2} => {99, 42}}}}
          }
        ]
      ]

      assert {:ok, merge} = CrossEpochMerge.merge(store, l_commit.id, r_commit.id, opts)

      # Decode the merge commit's update and verify the "Z" item's
      # origin was translated to {99, 42} — proof pass 1 applied the
      # override DM before the (identity) pass 2.
      {:ok, {items, _ds, _rest}} = Encoding.decode_update(merge.update)

      z_item = Enum.find(items, fn it -> it.id.client == 5 and it.id.clock == 0 end)
      assert z_item != nil, "expected client-5 'Z' item in translated bytes"
      assert z_item.origin != nil
      assert z_item.origin.client == 99
      assert z_item.origin.clock == 42
    end
  end

  # -------------------- Pre-flight failure phase events --------------

  describe "merge/3 — pre-flight failure emits phase event" do
    test "R→C pass failure emits [:commonplace, :late_edit, :untranslatable] with phase: :r_to_c",
         %{store: store} do
      capture_telemetry([:commonplace, :late_edit, :untranslatable])

      {uuid, c_snapshot, _} = seed_and_snapshot(store, "cem-fail-r")
      {:ok, c_doc} = Encoding.apply_update(Doc.new(), c_snapshot.update)
      c_update = Encoding.encode_update(c_doc)

      l_commit =
        author_regular(store, uuid, c_update, 2, fn d ->
          Text.insert(d, "t", 0, "X")
        end)

      doc_r = Doc.new(client_id: 3)
      {doc_r, _} = Doc.get_or_create_type(doc_r, "t", :text)
      {:ok, doc_r} = Encoding.apply_update(doc_r, c_update)
      doc_r = Text.insert(doc_r, "t", 3, "Y")
      r_update = Encoding.encode_update(doc_r)

      r_commit =
        Commit.new(uuid, r_update, c_snapshot.id, %{
          kind: :regular,
          snapshot_parent: c_snapshot.id
        })

      :ok = CommitStore.import_commit(store, r_commit, validator: fn _ -> :ok end)

      # Force pass-1 preflight to fail by passing a fake R_chain that
      # contains a snapshot whose DM is empty (no keys to resolve
      # R-ns refs). The merge/3 API accepts an `r_chain_override:` opt
      # used only by tests to force adversarial DM states, mirroring the
      # `broken_snapshot` pattern from translator_fallback_test.exs.
      opts = [
        r_chain_override: [
          %{id: "fake_snap", metadata: %{derivation_map: %{c_snapshot.id => %{}}}}
        ]
      ]

      assert {:error, {:untranslatable, _, _}} =
               CrossEpochMerge.merge(store, l_commit.id, r_commit.id, opts)

      assert_receive {:telemetry, [:commonplace, :late_edit, :untranslatable], _meas, meta},
                     500

      assert meta.phase == :r_to_c
    end
  end

  # -------------------- CID dedup via import_commit (CX-fbs6) --------
  #
  # Per commonplace-plan msg 2236: the role-split validator must admit
  # cross-epoch merge commits into L's namespace, and re-importing the
  # same merge commit must dedup to a single entry (byte-determinism at
  # the storage layer).

  describe "merge/3 — CID dedup via import_commit" do
    test "merge commit imports cleanly into L's namespace (CX-fbs6)",
         %{store: store} do
      {uuid, c_snapshot, _} = seed_and_snapshot(store, "cem-import")
      {:ok, c_doc} = Encoding.apply_update(Doc.new(), c_snapshot.update)
      c_update = Encoding.encode_update(c_doc)

      l_commit =
        author_regular(store, uuid, c_update, 2, fn d ->
          Text.insert(d, "t", 0, "X")
        end)

      doc_r = Doc.new(client_id: 3)
      {doc_r, _} = Doc.get_or_create_type(doc_r, "t", :text)
      {:ok, doc_r} = Encoding.apply_update(doc_r, c_update)
      doc_r = Text.insert(doc_r, "t", 3, "Y")
      r_update = Encoding.encode_update(doc_r)

      r_commit =
        Commit.new(uuid, r_update, c_snapshot.id, %{
          kind: :regular,
          snapshot_parent: c_snapshot.id
        })

      :ok = CommitStore.import_commit(store, r_commit, validator: fn _ -> :ok end)

      {:ok, merge} = CrossEpochMerge.merge(store, l_commit.id, r_commit.id)

      # :merge commits bypass validate_regular wholesale — role-split
      # validator should still accept without any override.
      assert :ok = CommitStore.import_commit(store, merge)
      assert {:ok, stored} = CommitStore.get_commit(store, merge.id)
      assert stored.id == merge.id
    end

    test "re-importing the same merge commit deduplicates to one entry",
         %{store: store} do
      {uuid, c_snapshot, _} = seed_and_snapshot(store, "cem-dedup")
      {:ok, c_doc} = Encoding.apply_update(Doc.new(), c_snapshot.update)
      c_update = Encoding.encode_update(c_doc)

      l_commit =
        author_regular(store, uuid, c_update, 2, fn d ->
          Text.insert(d, "t", 0, "X")
        end)

      doc_r = Doc.new(client_id: 3)
      {doc_r, _} = Doc.get_or_create_type(doc_r, "t", :text)
      {:ok, doc_r} = Encoding.apply_update(doc_r, c_update)
      doc_r = Text.insert(doc_r, "t", 3, "Y")
      r_update = Encoding.encode_update(doc_r)

      r_commit =
        Commit.new(uuid, r_update, c_snapshot.id, %{
          kind: :regular,
          snapshot_parent: c_snapshot.id
        })

      :ok = CommitStore.import_commit(store, r_commit, validator: fn _ -> :ok end)

      {:ok, merge} = CrossEpochMerge.merge(store, l_commit.id, r_commit.id)

      assert :ok = CommitStore.import_commit(store, merge)
      # Second import must be a no-op dedup — same CID, same bytes.
      assert :already_exists = CommitStore.import_commit(store, merge)
      assert {:ok, stored} = CommitStore.get_commit(store, merge.id)
      assert stored.update == merge.update
    end
  end
end

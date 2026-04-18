defmodule Commonplace.Store.TranslatorTest do
  @moduledoc """
  CX-fefz (Build 6.5): `Commonplace.Store.Translator.translate_edit/4` is
  the end-to-end entry point for late-edit translation. It composes:

  - 6.2 (`Namespace.inverse_derivation_map/1`) to invert the target
    snapshot's DM.
  - 6.3 (`LateEditTranslator.translate_update/2`) to rewrite the edit's
    reference fields through the inverse DM.
  - 6.4 (`LateEditPreflight.translate_and_validate/2`) to reject any
    edit whose refs don't resolve atomically — the translator is
    never invoked on a failed pre-flight.

  Emits red events on all outcomes:

  - `[:commonplace, :late_edit, :translated]` — success, with
    `%{edit_hash, target_snapshot, commit_id}`.
  - `[:commonplace, :late_edit, :untranslatable]` — failure, with
    `%{edit_hash, target_snapshot, reason: :case_a | :case_b, ref_id}`.

  Byte-determinism: two independent peers running `translate_edit/4` on
  the same `(edit, target_snapshot)` produce byte-identical translated
  commits. The store's content-addressing then collapses them into a
  single stored entry on import.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{Commit, CommitStore, Translator}
  alias Yelixer.{BlockStore, Doc, Encoding}
  alias Yelixer.Types.Text

  setup do
    dir = Path.join(System.tmp_dir!(), "translator_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"translator_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  # -------------------- Scenario builders --------------------

  # Seed a doc with client 1 inserting "abc" then snapshot. Returns
  # {doc_uuid, p_namespace_id, snapshot_commit, base_sv}. `p_namespace_id`
  # is the namespace the pre-snapshot regular commit lived in (genesis
  # for the first edit). `base_sv` is the state vector of the
  # pre-snapshot doc — feed it to `encode_diff/2` to build late edits
  # whose refs point at P's (now-tombstoned) items.
  defp seed_and_snapshot(store, uuid) do
    {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)

    doc_p = Doc.new(client_id: 1)
    {doc_p, _} = Doc.get_or_create_type(doc_p, "t", :text)
    doc_p = Text.insert(doc_p, "t", 0, "abc")
    e_p = Encoding.encode_update(doc_p)

    _reg = CommitStore.create_chained_commit(store, uuid, e_p, %{kind: :regular})
    {:ok, snapshot} = CommitStore.snapshot(store, uuid)

    {uuid, genesis.id, snapshot, BlockStore.state_vector(doc_p.store)}
  end

  # Build a late edit that continues "abc" with an appended run by
  # client 2 — this yields origin/right_origin refs pointing at P's
  # client-1 items (external refs that a translator must resolve via
  # the inverse DM).
  defp late_edit_commit(uuid, p_namespace_id, base_sv, appended) do
    doc_b = Doc.new(client_id: 2)
    {doc_b, _} = Doc.get_or_create_type(doc_b, "t", :text)
    {:ok, doc_b} = Encoding.apply_update(doc_b, rebuild_p_update())
    doc_b = Text.insert(doc_b, "t", 3, appended)
    edit_update = Encoding.encode_diff(doc_b, base_sv)

    Commit.new(uuid, edit_update, nil, %{kind: :regular, snapshot_parent: p_namespace_id})
  end

  defp rebuild_p_update do
    doc_p = Doc.new(client_id: 1)
    {doc_p, _} = Doc.get_or_create_type(doc_p, "t", :text)
    doc_p = Text.insert(doc_p, "t", 0, "abc")
    Encoding.encode_update(doc_p)
  end

  # Attach a telemetry handler to a concrete event path for the
  # duration of a test. Returns a ref you can flush via `assert_receive`.
  defp capture_telemetry(event) do
    test_pid = self()
    handler_id = {__MODULE__, event, make_ref()}

    :telemetry.attach(
      handler_id,
      event,
      fn ^event, measurements, metadata, _cfg ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  # -------------------- Success path --------------------

  describe "translate_edit/4 — success path" do
    test "returns {:ok, translated_commit} with target_snapshot as parent",
         %{store: store} do
      {uuid, p_id, snapshot, base_sv} = seed_and_snapshot(store, "s-ok")
      edit = late_edit_commit(uuid, p_id, base_sv, "de")

      assert {:ok, translated} = Translator.translate_edit(store, edit, snapshot.id)

      assert %Commit{} = translated
      assert translated.parent_id == snapshot.id
      assert translated.doc_uuid == uuid
      assert translated.metadata[:kind] == :regular
      assert translated.metadata[:snapshot_parent] == snapshot.id
      assert is_binary(translated.update)
    end

    test "emits [:commonplace, :late_edit, :translated] with edit_hash, target_snapshot, commit_id",
         %{store: store} do
      capture_telemetry([:commonplace, :late_edit, :translated])

      {uuid, p_id, snapshot, base_sv} = seed_and_snapshot(store, "s-telem")
      edit = late_edit_commit(uuid, p_id, base_sv, "de")

      {:ok, translated} = Translator.translate_edit(store, edit, snapshot.id)

      assert_receive {:telemetry, [:commonplace, :late_edit, :translated], _meas, metadata}, 500
      assert metadata.edit_hash == edit.id
      assert metadata.target_snapshot == snapshot.id
      assert metadata.commit_id == translated.id
    end

    test "translated update references S-namespace items (not P-namespace)",
         %{store: store} do
      {uuid, p_id, snapshot, base_sv} = seed_and_snapshot(store, "s-ns")
      edit = late_edit_commit(uuid, p_id, base_sv, "de")

      {:ok, translated} = Translator.translate_edit(store, edit, snapshot.id)

      # The translated update's refs should resolve against S (the
      # snapshot's namespace). Apply it on top of S and confirm no
      # orphaned-item errors surface — if a ref still pointed at P,
      # reconstruct-from-snapshot would leave it dangling.
      {:ok, doc_s} = Encoding.apply_update(Doc.new(), snapshot.update)
      assert {:ok, _doc_applied} = Encoding.apply_update(doc_s, translated.update)
    end

    # CX-hzdc: envelope-structure docs (root YMap + named "content"
    # YText/YMap/YArray — what every real commonplace tree doc uses)
    # must round-trip the primary translator path. Previously failed
    # with spurious :case_b because the snapshotter's position-based
    # pair_ids mispaired entries when snapshot_update iterated
    # source.types in map-key order instead of source-clock order.
    test "primary path succeeds on envelope-structure text doc (CX-hzdc)",
         %{store: store} do
      uuid = "s-envelope"
      {:ok, _genesis} = CommitStore.ensure_genesis(store, uuid)

      doc_p =
        Doc.new(client_id: 1)
        |> ContentType.create(:text, "n")
        |> ContentType.insert_text(0, "abc")

      e_p = Encoding.encode_update(doc_p)
      base_sv = BlockStore.state_vector(doc_p.store)

      _reg = CommitStore.create_chained_commit(store, uuid, e_p, %{kind: :regular})
      {:ok, snapshot} = CommitStore.snapshot(store, uuid)
      p_namespace = snapshot.metadata[:snapshot_parents] |> hd()

      doc_b = Doc.new(client_id: 2)
      {:ok, doc_b} = Encoding.apply_update(doc_b, e_p)
      doc_b = ContentType.insert_text(doc_b, 3, "de")
      edit_update = Encoding.encode_diff(doc_b, base_sv)
      edit = Commit.new(uuid, edit_update, nil, %{kind: :regular, snapshot_parent: p_namespace})

      assert {:ok, translated} = Translator.translate_edit(store, edit, snapshot.id)

      # Apply the translated commit on top of S and verify the final
      # content is "abcde" — proves refs resolved to the right items.
      {:ok, doc_s} = Encoding.apply_update(Doc.new(), snapshot.update)
      {:ok, doc_final} = Encoding.apply_update(doc_s, translated.update)
      assert ContentType.get_content(doc_final) == "abcde"
    end
  end

  # -------------------- :case_a (parent / delete_set) --------------------

  describe "translate_edit/4 — :case_a failure" do
    test "emits :untranslatable with reason: :case_a and ref_id when a delete-set target is tombstoned",
         %{store: store} do
      capture_telemetry([:commonplace, :late_edit, :untranslatable])

      uuid = "s-case-a"
      {:ok, _genesis} = CommitStore.ensure_genesis(store, uuid)

      doc_p = Doc.new(client_id: 1)
      {doc_p, _} = Doc.get_or_create_type(doc_p, "t", :text)
      doc_p = Text.insert(doc_p, "t", 0, "abc")
      e_p = Encoding.encode_update(doc_p)
      _reg = CommitStore.create_chained_commit(store, uuid, e_p, %{kind: :regular})
      {:ok, snapshot} = CommitStore.snapshot(store, uuid)
      p_namespace = snapshot.metadata[:snapshot_parents] |> hd()

      # Build a late edit that DELETES one of P's items. In S the DM
      # only covers live items; to manufacture :case_a we corrupt the
      # snapshot's DM by removing the delete target from it.
      doc_b = Doc.new(client_id: 2)
      {doc_b, _} = Doc.get_or_create_type(doc_b, "t", :text)
      {:ok, doc_b} = Encoding.apply_update(doc_b, e_p)
      doc_b = Text.delete(doc_b, "t", 1, 1)
      base_sv = BlockStore.state_vector(doc_p.store)
      edit_update = Encoding.encode_diff(doc_b, base_sv)

      edit = Commit.new(uuid, edit_update, nil, %{kind: :regular, snapshot_parent: p_namespace})

      # Corrupt the snapshot's DM: drop ALL entries so every lookup fails.
      broken_dm = %{p_namespace => %{}}
      broken_snapshot = put_in(snapshot.metadata[:derivation_map], broken_dm)

      assert {:error, {:untranslatable, :case_a, _ref_id}} =
               Translator.translate_edit_with_snapshot(edit, broken_snapshot)

      assert_receive {:telemetry, [:commonplace, :late_edit, :untranslatable], _meas, metadata},
                     500

      assert metadata.reason == :case_a
      assert metadata.edit_hash == edit.id
      assert metadata.target_snapshot == broken_snapshot.id
      assert is_tuple(metadata.ref_id)
    end
  end

  # -------------------- :case_b (origin / right_origin) --------------------

  describe "translate_edit/4 — :case_b failure" do
    test "emits :untranslatable with reason: :case_b and ref_id when an origin is tombstoned",
         %{store: store} do
      capture_telemetry([:commonplace, :late_edit, :untranslatable])

      uuid = "s-case-b"
      {:ok, _genesis} = CommitStore.ensure_genesis(store, uuid)

      doc_p = Doc.new(client_id: 1)
      {doc_p, _} = Doc.get_or_create_type(doc_p, "t", :text)
      doc_p = Text.insert(doc_p, "t", 0, "abc")
      e_p = Encoding.encode_update(doc_p)
      _reg = CommitStore.create_chained_commit(store, uuid, e_p, %{kind: :regular})
      {:ok, snapshot} = CommitStore.snapshot(store, uuid)
      p_namespace = snapshot.metadata[:snapshot_parents] |> hd()

      doc_b = Doc.new(client_id: 2)
      {doc_b, _} = Doc.get_or_create_type(doc_b, "t", :text)
      {:ok, doc_b} = Encoding.apply_update(doc_b, e_p)
      doc_b = Text.insert(doc_b, "t", 3, "de")
      base_sv = BlockStore.state_vector(doc_p.store)
      edit_update = Encoding.encode_diff(doc_b, base_sv)

      edit = Commit.new(uuid, edit_update, nil, %{kind: :regular, snapshot_parent: p_namespace})

      # Corrupt snapshot's DM — drop every entry so origin refs miss.
      broken_snapshot = put_in(snapshot.metadata[:derivation_map], %{p_namespace => %{}})

      assert {:error, {:untranslatable, :case_b, _ref_id}} =
               Translator.translate_edit_with_snapshot(edit, broken_snapshot)

      assert_receive {:telemetry, [:commonplace, :late_edit, :untranslatable], _meas, metadata},
                     500

      assert metadata.reason == :case_b
      assert metadata.edit_hash == edit.id
      assert metadata.target_snapshot == broken_snapshot.id
      assert is_tuple(metadata.ref_id)
    end
  end

  # -------------------- Byte-determinism --------------------

  describe "translate_edit/4 — byte-determinism" do
    test "two independent calls on the same (edit, snapshot) produce identical commits",
         %{store: store} do
      {uuid, p_id, snapshot, base_sv} = seed_and_snapshot(store, "s-det")
      edit = late_edit_commit(uuid, p_id, base_sv, "de")

      {:ok, c1} = Translator.translate_edit(store, edit, snapshot.id)
      {:ok, c2} = Translator.translate_edit(store, edit, snapshot.id)

      assert c1.id == c2.id
      assert c1.update == c2.update
      assert c1.parent_id == c2.parent_id
      assert c1.metadata == c2.metadata
    end
  end

  # CID dedup (two translated commits imported into the store collapsing
  # to one entry) would also be a nice property to verify here, but the
  # current namespace validator (CX-ch5) rejects regular commits that
  # introduce a new item-authorship client outside the target snapshot's
  # namespace. Late-edit translation inherently introduces the editing
  # peer's client id; threading that through the validator cleanly is a
  # separate concern from 6.5's composition bead. Byte-determinism
  # (above) already proves two peers produce identical commit bytes —
  # the content-addressed store collapses them once the validator gap
  # is closed.
end

defmodule Commonplace.Sync.NodeSyncImportHookTest do
  @moduledoc """
  CX-7cm1: NodeSync hook wiring LateEditAutoTranslator into the import
  path.

  `NodeSync.import_with_translation(store, commit, opts)` wraps
  `CommitStoreClient.import_commit/2` with the CX-atk3 primitive so the
  sync path auto-recovers when a peer ships an edit written against an
  older snapshot than the local head.

  Per commonplace-plan msg 2282:

  - `{:ok, :no_translation_needed}` → import original as-is (existing
    behavior).
  - `{:ok, :translated, c}` / `{:ok, :fallback, c}` → import the
    translated commit *instead* of the original cross-epoch one.
  - `{:ok, :skipped, reason}` → import original AND emit
    `[:commonplace, :late_edit, :auto_skip_stored]` so divergence is
    visible rather than silent. Whether the original's raw import
    succeeds depends on the namespace validator — telemetry is the
    signal observers can rely on.
  - Default `fallback: true` per design.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Sync.NodeSync
  alias Commonplace.Store.{Commit, CommitStore, Namespace}
  alias Yelixer.{BlockStore, Doc, Encoding}
  alias Yelixer.Types.Text

  setup do
    dir = Path.join(System.tmp_dir!(), "nsit_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"nsit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)

    %{store: name}
  end

  # Seed a doc with client 1 writing "abc", then snapshot. Returns
  # {uuid, p_namespace_id, snapshot, base_sv}. Mirrors the fixture in
  # CX-atk3's test so behavior is directly comparable.
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

  defp late_edit_off_p(uuid, p_namespace, base_sv, appended) do
    doc_b = Doc.new(client_id: 2)
    {doc_b, _} = Doc.get_or_create_type(doc_b, "t", :text)
    {:ok, doc_b} = Encoding.apply_update(doc_b, rebuild_p_update())
    doc_b = Text.insert(doc_b, "t", 3, appended)
    edit_update = Encoding.encode_diff(doc_b, base_sv)

    Commit.new(uuid, edit_update, nil, %{kind: :regular, snapshot_parent: p_namespace})
  end

  # Build an edit whose update is VALID Yjs bytes but whose
  # snapshot_parent declaration points at a namespace the store doesn't
  # know about — forces the primitive's primary path to fail before any
  # translation can happen.
  defp aligned_edit(uuid, snapshot, base_sv, appended) do
    doc_b = Doc.new(client_id: 2)
    {doc_b, _} = Doc.get_or_create_type(doc_b, "t", :text)
    {:ok, doc_b} = Encoding.apply_update(doc_b, rebuild_p_update())
    doc_b = Text.insert(doc_b, "t", 3, appended)
    edit_update = Encoding.encode_diff(doc_b, base_sv)

    Commit.new(uuid, edit_update, nil, %{
      kind: :regular,
      snapshot_parent: Namespace.current_namespace(snapshot)
    })
  end

  defp rebuild_p_update do
    doc_p = Doc.new(client_id: 1)
    {doc_p, _} = Doc.get_or_create_type(doc_p, "t", :text)
    doc_p = Text.insert(doc_p, "t", 0, "abc")
    Encoding.encode_update(doc_p)
  end

  defp capture_telemetry(event) do
    test_pid = self()
    handler_id = {__MODULE__, event, make_ref()}

    :telemetry.attach(
      handler_id,
      event,
      fn ^event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  describe "import_with_translation/3 — aligned commit passthrough" do
    test "stores the original commit when snapshot_parent matches local head's namespace",
         %{store: store} do
      uuid = "hook-aligned"
      {_uuid, _p_id, snapshot, base_sv} = seed_and_snapshot(store, uuid)
      aligned = aligned_edit(uuid, snapshot, base_sv, "de")

      assert :ok = NodeSync.import_with_translation(store, aligned)
      assert {:ok, stored} = CommitStore.get_commit(store, aligned.id)
      assert stored.id == aligned.id
    end

    test "does not emit :auto_skip_stored for aligned commits", %{store: store} do
      capture_telemetry([:commonplace, :late_edit, :auto_skip_stored])

      uuid = "hook-aligned-no-skip"
      {_uuid, _p_id, snapshot, base_sv} = seed_and_snapshot(store, uuid)
      aligned = aligned_edit(uuid, snapshot, base_sv, "de")

      :ok = NodeSync.import_with_translation(store, aligned)

      refute_receive {:telemetry, [:commonplace, :late_edit, :auto_skip_stored], _, _}, 100
    end
  end

  describe "import_with_translation/3 — translated commit replaces the original" do
    test "stores the translated commit (not the cross-epoch original)",
         %{store: store} do
      uuid = "hook-translated"
      {_uuid, p_id, snapshot, base_sv} = seed_and_snapshot(store, uuid)
      incoming = late_edit_off_p(uuid, p_id, base_sv, "de")

      # Sanity: the incoming commit is stale.
      refute incoming.metadata[:snapshot_parent] == Namespace.current_namespace(snapshot)

      assert :ok = NodeSync.import_with_translation(store, incoming)

      # The original cross-epoch commit is NOT the one we kept.
      assert :none = CommitStore.get_commit(store, incoming.id)

      # The store now holds a commit chained onto snapshot.id — the
      # translated replacement — with snapshot_parent = snapshot.id.
      # `import_commit` does NOT advance :latest (per its docs), so use
      # all_commit_ids_for_doc which scans the full index.
      ids = CommitStore.all_commit_ids_for_doc(store, uuid)

      translated =
        for id <- MapSet.to_list(ids),
            {:ok, c} = CommitStore.get_commit(store, id),
            c.parent_id == snapshot.id,
            c.metadata[:snapshot_parent] == snapshot.id,
            c.metadata[:kind] == :regular,
            do: c

      assert length(translated) == 1
    end
  end

  describe "import_with_translation/3 — skipped case emits telemetry" do
    test "with fallback: false on an untranslatable edit, emits :auto_skip_stored",
         %{store: store} do
      capture_telemetry([:commonplace, :late_edit, :auto_skip_stored])

      uuid = "hook-skipped"
      {_uuid, _p_id, snapshot, _} = seed_and_snapshot(store, uuid)

      bogus_ns = String.duplicate("0", 64)
      refute Namespace.current_namespace(snapshot) == bogus_ns

      # <<1, 0>> is a malformed Yjs update — primary translate path
      # fails at decode, and with fallback: false the primitive returns
      # {:ok, :skipped, reason}. The hook should then emit telemetry
      # and forward the original to import_commit (raw import may still
      # be rejected by the namespace validator — that's fine; telemetry
      # is the signal this test guards).
      edit =
        Commit.new(uuid, <<1, 0>>, nil, %{
          kind: :regular,
          snapshot_parent: bogus_ns
        })

      _ = NodeSync.import_with_translation(store, edit, fallback: false)

      assert_receive {:telemetry, [:commonplace, :late_edit, :auto_skip_stored], _meas, meta},
                     500

      assert meta.edit_hash == edit.id
      assert Map.has_key?(meta, :reason)
    end

    test ":auto_skip_stored meta carries edit_hash and reason fields", %{store: store} do
      capture_telemetry([:commonplace, :late_edit, :auto_skip_stored])

      uuid = "hook-skip-meta"
      {_uuid, _p_id, _snapshot, _} = seed_and_snapshot(store, uuid)

      bogus_ns = String.duplicate("f", 64)

      edit =
        Commit.new(uuid, <<1, 0>>, nil, %{
          kind: :regular,
          snapshot_parent: bogus_ns
        })

      _ = NodeSync.import_with_translation(store, edit, fallback: false)

      assert_receive {:telemetry, [:commonplace, :late_edit, :auto_skip_stored], _, meta}, 500
      assert is_binary(meta.edit_hash)
      assert Map.has_key?(meta, :reason)
    end
  end

  describe "import_with_translation/3 — default fallback: true" do
    test "default call (no opts) goes through primary path for translatable edits",
         %{store: store} do
      uuid = "hook-default"
      {_uuid, p_id, _snapshot, base_sv} = seed_and_snapshot(store, uuid)
      incoming = late_edit_off_p(uuid, p_id, base_sv, "de")

      # No opts — default fallback: true. Primary succeeds on a clean
      # DM, so no :auto_skip_stored should fire.
      capture_telemetry([:commonplace, :late_edit, :auto_skip_stored])

      assert :ok = NodeSync.import_with_translation(store, incoming)

      refute_receive {:telemetry, [:commonplace, :late_edit, :auto_skip_stored], _, _}, 100
    end
  end
end

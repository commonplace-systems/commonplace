defmodule Commonplace.Audit.LwwLossTest do
  @moduledoc """
  CX-tdkq.30: detector for persisted Find-1 (14520f7) LWW map-overwrite loss.

  Pre-fix, a causally-later YMap.set / set_attribute from a SMALLER client
  id encoded its replacement item with origin=nil. On replay the integrator
  treats it as concurrent, YATA places it left of the old value, map
  conflict resolution tombstones it as the "concurrent loser", and the
  writer's delete-set kills the old item — the key reads nil. The bad
  origin=nil bytes are PERSISTED in commit updates, so the loss manifests
  on every reconstruction even after the writer-side fix.

  These tests synthesize pre-fix-shaped bytes by stripping the origin from
  a post-fix overwrite item before encoding, then assert the auditor flags
  exactly that chain and nothing legitimate.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Audit.LwwLoss
  alias Commonplace.Store.CommitStore
  alias Yelixer.{BlockStore, Doc, Encoding}
  alias Yelixer.Types.YMap

  setup do
    dir = Path.join(System.tmp_dir!(), "lww_audit_#{:rand.uniform(999_999_999)}")
    store_name = :"lww_audit_store_#{System.unique_integer([:positive])}"
    {:ok, store} = CommitStore.start_link(data_dir: dir, name: store_name)

    on_exit(fn ->
      if Process.alive?(store), do: GenServer.stop(store)
      File.rm_rf!(dir)
    end)

    %{store: store_name}
  end

  # Builds {u1, u2} where u1 sets "k" => "v1" from a LARGE client id and
  # u2 overwrites "k" => "v2" from a SMALL client id. With corrupt?: true
  # the overwrite item's origin is stripped, replicating pre-fix bytes.
  defp overwrite_updates(corrupt?) do
    doc_a = Doc.new(client_id: 200)
    doc_a = YMap.set(doc_a, "m", "k", "v1")
    u1 = Encoding.encode_update(doc_a)
    sv1 = BlockStore.state_vector(doc_a.store)

    doc_b = Doc.new(client_id: 5)
    {:ok, doc_b} = Encoding.apply_update(doc_b, u1)
    doc_b = YMap.set(doc_b, "m", "k", "v2")

    doc_b = if corrupt?, do: strip_origins(doc_b, 5), else: doc_b
    u2 = Encoding.encode_diff(doc_b, sv1)
    {u1, u2}
  end

  defp strip_origins(%Doc{store: store} = doc, client) do
    stripped = for item <- BlockStore.client_blocks(store, client), do: %{item | origin: nil}

    store = %{store | clients: Map.put(store.clients, client, stripped)}
    %{doc | store: BlockStore.invalidate_tuple_cache(store, client)}
  end

  defp seed_chain(store, updates) do
    uuid = UUID.uuid4()
    [first | rest] = updates
    %{id: _} = CommitStore.create_commit(store, uuid, first, nil)

    for u <- rest do
      %{id: _} = CommitStore.create_chained_commit(store, uuid, u)
    end

    uuid
  end

  test "pre-fix origin=nil overwrite still reads nil on replay (loss premise)" do
    {u1, u2} = overwrite_updates(true)
    doc = Doc.new(client_id: 999)
    {:ok, doc} = Encoding.apply_update(doc, u1)
    {:ok, doc} = Encoding.apply_update(doc, u2)
    assert YMap.get(doc, "m", "k") == nil
  end

  test "flags a doc whose chain carries a pre-fix origin=nil overwrite", %{store: store} do
    {u1, u2} = overwrite_updates(true)
    uuid = seed_chain(store, [u1, u2])

    assert {:ok, [finding]} = LwwLoss.audit_doc(store, uuid)
    assert finding.key == {"m", "k"}
    assert finding.expected_content == "v2"
    assert finding.full_replay == :tombstoned
    assert finding.production == :tombstoned
  end

  test "does not flag a post-fix (origin-threaded) overwrite", %{store: store} do
    {u1, u2} = overwrite_updates(false)
    uuid = seed_chain(store, [u1, u2])

    assert {:ok, []} = LwwLoss.audit_doc(store, uuid)
  end

  test "does not flag an intentional key delete", %{store: store} do
    doc = Doc.new(client_id: 200)
    doc = YMap.set(doc, "m", "k", "v1")
    u1 = Encoding.encode_update(doc)
    sv1 = BlockStore.state_vector(doc.store)

    doc = YMap.delete(doc, "m", "k")
    u2 = Encoding.encode_diff(doc, sv1)

    uuid = seed_chain(store, [u1, u2])
    assert {:ok, []} = LwwLoss.audit_doc(store, uuid)
  end

  test "audit_store reports only anomalous docs", %{store: store} do
    {u1c, u2c} = overwrite_updates(true)
    bad_uuid = seed_chain(store, [u1c, u2c])

    {u1, u2} = overwrite_updates(false)
    _good_uuid = seed_chain(store, [u1, u2])

    assert {:ok, findings} = LwwLoss.audit_store(store)
    assert Map.keys(findings) == [bad_uuid]
  end
end

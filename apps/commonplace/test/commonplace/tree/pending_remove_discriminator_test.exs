defmodule Commonplace.Tree.PendingRemoveDiscriminatorTest do
  @moduledoc """
  CX-zfzn measurement: distinguish pending-item deletion from settled deletion.

  This is deliberately a behavior test, not a fix. The incident-shaped arm
  reconstructs the latest of 17 full-state schema commits and proves the
  target item is in `BlockStore.client_pending` before calling
  `Schema.remove_entry/2`. The control materializes the identical document
  before performing the same delete and round-trip.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Yelixer.{DeleteSet, Doc, Encoding, Item}

  @birth_client 10_001
  @import_client 20_002
  @reader_client 30_003
  @doc_uuid "cx-zfzn-pending-remove"
  @target "bd"

  setup do
    unique = System.unique_integer([:positive])
    data_dir = Path.join(System.tmp_dir!(), "cx_zfzn_#{unique}")
    store = :"cx_zfzn_store_#{unique}"

    File.mkdir_p!(data_dir)
    start_supervised!({CommitStore, data_dir: data_dir, name: store})
    on_exit(fn -> File.rm_rf!(data_dir) end)

    %{store: store}
  end

  test "remove_entry tombstones a target still in client_pending and survives re-encode", %{
    store: store
  } do
    pending_doc = build_incident_shaped_doc(store)
    pending_item = pending_item_for_key!(pending_doc, @target)

    assert pending_counts(pending_doc) == %{@birth_client => 3, @import_client => 16}
    assert pending_keys(pending_doc, @birth_client) == ["bd", "chat", "version"]
    assert pending_item.id.client == @birth_client
    assert Map.has_key?(pending_doc.store.client_pending, @birth_client)
    assert Schema.entries(pending_doc)[@target]["node_id"] == "bd-node"

    removed = Schema.remove_entry(pending_doc, @target)

    refute Map.has_key?(Schema.entries(removed), @target)
    assert DeleteSet.deleted?(removed.delete_set, pending_item.id.client, pending_item.id.clock)

    round_tripped = round_trip(removed)

    refute Map.has_key?(Schema.entries(round_tripped), @target)

    assert DeleteSet.deleted?(
             round_tripped.delete_set,
             pending_item.id.client,
             pending_item.id.clock
           )
  end

  test "control: remove_entry tombstones the same target after integration", %{store: store} do
    pending_doc = build_incident_shaped_doc(store)
    target_item = pending_item_for_key!(pending_doc, @target)
    integrated_doc = Doc.gc(pending_doc)

    assert integrated_doc.store.client_pending == %{}
    assert integrated_item?(integrated_doc, target_item)
    assert Schema.entries(integrated_doc)[@target]["node_id"] == "bd-node"

    removed = Schema.remove_entry(integrated_doc, @target)

    refute Map.has_key?(Schema.entries(removed), @target)
    assert DeleteSet.deleted?(removed.delete_set, target_item.id.client, target_item.id.clock)

    round_tripped = round_trip(removed)

    refute Map.has_key?(Schema.entries(round_tripped), @target)

    assert DeleteSet.deleted?(
             round_tripped.delete_set,
             target_item.id.client,
             target_item.id.clock
           )
  end

  defp build_incident_shaped_doc(store) do
    birth_doc =
      Schema.new_schema(client_id: @birth_client)
      |> Schema.add_file(@target, "bd-node")
      |> Schema.add_file("chat", "chat-node")

    CommitStore.create_commit(
      store,
      @doc_uuid,
      Encoding.encode_update(birth_doc),
      nil,
      %{}
    )

    Enum.each(1..16, fn generation ->
      {:ok, import_doc} =
        DocBuilder.reconstruct_snapshot(store, @doc_uuid, client_id: @import_client)

      import_doc =
        Schema.add_file(import_doc, "import-#{generation}", "import-node-#{generation}")

      CommitStore.create_chained_commit(
        store,
        @doc_uuid,
        Encoding.encode_update(import_doc),
        %{}
      )
    end)

    content_commits =
      store
      |> CommitStore.commit_log(@doc_uuid)
      |> Enum.reject(&(Map.get(&1.metadata, :kind) == :genesis))

    assert length(content_commits) == 17

    {:ok, doc} =
      DocBuilder.reconstruct_snapshot(store, @doc_uuid, client_id: @reader_client)

    doc
  end

  defp pending_item_for_key!(doc, key) do
    doc.store.client_pending
    |> Map.values()
    |> Enum.flat_map(&:gb_trees.values/1)
    |> Enum.find(fn %Item{} = item -> item.parent_sub == key and not item.deleted end)
    |> case do
      nil -> flunk("expected #{inspect(key)} item in store.client_pending")
      item -> item
    end
  end

  defp pending_counts(doc) do
    Map.new(doc.store.client_pending, fn {client, tree} ->
      {client, :gb_trees.size(tree)}
    end)
  end

  defp pending_keys(doc, client) do
    doc.store.client_pending
    |> Map.fetch!(client)
    |> :gb_trees.values()
    |> Enum.map(& &1.parent_sub)
    |> Enum.sort()
  end

  defp integrated_item?(doc, target_item) do
    doc.store.clients
    |> Map.get(target_item.id.client, [])
    |> Enum.any?(&(&1.id == target_item.id and not &1.deleted))
  end

  defp round_trip(doc) do
    {:ok, fresh} =
      Encoding.apply_update(
        Doc.new(client_id: @reader_client + 1),
        Encoding.encode_update(doc)
      )

    fresh
  end
end

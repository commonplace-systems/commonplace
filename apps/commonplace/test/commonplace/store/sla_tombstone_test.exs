defmodule Commonplace.Store.SlaTombstoneTest do
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Projection
  alias Commonplace.Store.{CommitStore, CommitStoreClient, SlaTombstone}

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "sla_tombstone_#{System.unique_integer([:positive])}")

    store = :"sla_tombstone_store_#{System.unique_integer([:positive])}"
    start_supervised!({CommitStore, data_dir: data_dir, name: store})
    on_exit(fn -> File.rm_rf!(data_dir) end)

    {public_key, private_key} = Signing.generate_keypair()

    signing_context = %SigningContext{
      identity_uuid: "sla-operator",
      private_key: private_key,
      public_key: public_key
    }

    %{store: store, signing_context: signing_context}
  end

  test "writer constructs a signed receipt that verifies and tampering fails", ctx do
    tombstone = tombstone(ctx, [commit_id(1), commit_id(2)])

    assert :ok = SlaTombstone.verify(tombstone)
    assert :ok = CommitStoreClient.store_sla_tombstone(ctx.store, tombstone)

    signature_tampered = %{tombstone | signature: :binary.copy(<<0>>, 64)}
    assert {:error, :invalid_signature} = SlaTombstone.verify(signature_tampered)

    field_tampered = %{tombstone | dropped_hash: commit_id(99)}
    assert {:error, {:id_mismatch, _computed, _claimed}} = SlaTombstone.verify(field_tampered)

    assert {:error, {:invalid_sla_tombstone, {:id_mismatch, _computed, _claimed}}} =
             CommitStoreClient.store_sla_tombstone(ctx.store, field_tampered)
  end

  test "projection names an SLA eviction and cites its subtree and tombstone", ctx do
    missing_id = commit_id(3)
    tombstone = tombstone(ctx, [commit_id(2), missing_id])
    assert :ok = CommitStoreClient.store_sla_tombstone(ctx.store, tombstone)

    assert {:error,
            {:evicted_per_sla,
             %{subtree_id: "subtree-a", tombstone_id: tombstone_id, commit_id: ^missing_id}}} =
             Projection.project_at("doc-a", missing_id, store: ctx.store)

    assert tombstone_id == tombstone.id
  end

  test "projection preserves ordinary not-found when no tombstone covers the range", ctx do
    missing_id = commit_id(4)

    assert {:error, {:commit_not_found, ^missing_id}} =
             Projection.project_at("doc-a", missing_id, store: ctx.store)
  end

  defp tombstone(ctx, commit_ids) do
    assert {:ok, tombstone} =
             SlaTombstone.new(
               %{
                 subtree_id: "subtree-a",
                 sla: %{tier: "compactable", retention: "after-snapshot", note: nil},
                 commit_ids: commit_ids,
                 evicted_at: "2026-08-13T00:00:00Z",
                 dropped_hash: commit_id(42)
               },
               ctx.signing_context
             )

    tombstone
  end

  defp commit_id(byte), do: :binary.copy(<<byte>>, 32)
end

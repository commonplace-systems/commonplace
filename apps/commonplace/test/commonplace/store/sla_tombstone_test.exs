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

    prior_trusted_signers = Application.fetch_env(:commonplace, :trusted_tombstone_signers)

    Application.put_env(:commonplace, :trusted_tombstone_signers, %{
      signing_context.identity_uuid => signing_context.public_key
    })

    on_exit(fn -> restore_trusted_signers(prior_trusted_signers) end)

    %{store: store, signing_context: signing_context}
  end

  test "verification requires a configured trusted signer and rejects another keypair", ctx do
    trusted_context = fixture_signing_context("trusted-eviction-signer", 17)
    other_context = fixture_signing_context("untrusted-eviction-signer", 29)

    Application.put_env(:commonplace, :trusted_tombstone_signers, %{
      trusted_context.identity_uuid => trusted_context.public_key
    })

    trusted_tombstone = tombstone(%{ctx | signing_context: trusted_context}, [commit_id(1)])
    other_tombstone = tombstone(%{ctx | signing_context: other_context}, [commit_id(2)])

    trusted_result = SlaTombstone.verify(trusted_tombstone)
    untrusted_result = SlaTombstone.verify(other_tombstone)

    Application.delete_env(:commonplace, :trusted_tombstone_signers)
    no_anchor_result = SlaTombstone.verify(other_tombstone)

    assert trusted_result == :ok

    assert untrusted_result ==
             {:error, {:untrusted_tombstone_signer, other_tombstone.signer_id}}

    assert no_anchor_result == {:error, :no_eviction_anchor_configured}
    assert other_tombstone.signer_public_key != trusted_context.public_key
    assert MapSet.size(MapSet.new([trusted_result, untrusted_result, no_anchor_result])) == 3

    IO.puts("AFTER_TRUSTED_SIGNER=#{inspect(trusted_result)}")
    IO.puts("AFTER_UNTRUSTED_SIGNER=#{inspect(untrusted_result)}")
    IO.puts("AFTER_NO_EVICTION_ANCHOR=#{inspect(no_anchor_result)}")
    IO.puts("AFTER_OUTCOMES_DIFFER=true")
    IO.puts("FIXTURE_SIGNER_ID=#{other_tombstone.signer_id}")
    IO.puts("FIXTURE_KEYS_DIFFER=true")
    IO.puts("FIXTURE_TOMBSTONE_ID=#{Base.encode16(other_tombstone.id, case: :lower)}")
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

  defp fixture_signing_context(identity_uuid, seed_byte) do
    {public_key, private_key} =
      :crypto.generate_key(:eddsa, :ed25519, :binary.copy(<<seed_byte>>, 32))

    %SigningContext{
      identity_uuid: identity_uuid,
      private_key: private_key,
      public_key: public_key
    }
  end

  defp restore_trusted_signers({:ok, trusted_signers}),
    do: Application.put_env(:commonplace, :trusted_tombstone_signers, trusted_signers)

  defp restore_trusted_signers(:error),
    do: Application.delete_env(:commonplace, :trusted_tombstone_signers)
end

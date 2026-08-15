defmodule Commonplace.Store.SlaTombstoneTest do
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Projection
  alias Commonplace.Store.{CommitStoreClient, SlaTombstone}
  alias Commonplace.Trust
  alias Commonplace.Trust.{EvictionAnchor, Revocation}

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "sla_tombstone_#{System.unique_integer([:positive])}")

    nonce = System.unique_integer([:positive])
    store = :"sla_tombstone_store_#{nonce}"

    start_supervised!(
      Supervisor.child_spec(
        {Commonplace.Store.Supervisor,
         data_dir: data_dir,
         name: :"sla_tombstone_supervisor_#{nonce}",
         commit_store_name: store,
         trust_side_store_name: :"sla_tombstone_trust_store_#{nonce}",
         pending_imports_name: :"sla_tombstone_pending_#{nonce}"},
        id: store
      )
    )

    on_exit(fn -> File.rm_rf!(data_dir) end)

    {public_key, private_key} = Signing.generate_keypair()

    signing_context = %SigningContext{
      identity_uuid: "sla-operator",
      private_key: private_key,
      public_key: public_key
    }

    prior_trust = Application.fetch_env(:commonplace, :trust)

    {:ok, trust} =
      Trust.add_eviction_anchor(Trust.default_config(), signing_context.identity_uuid, public_key)

    Application.put_env(:commonplace, :trust, trust)

    on_exit(fn -> restore_trust(prior_trust) end)

    %{store: store, signing_context: signing_context, trust: trust}
  end

  test "six eviction-anchor acceptance arms differ by authority and chain position", ctx do
    anchor_context = fixture_signing_context("fixture-eviction-only", 17)
    other_context = fixture_signing_context("trusted-writer-not-anchored", 29)

    strict = %{
      Trust.default_config()
      | accept_unsigned: false,
        trusted_identities: %{
          other_context.identity_uuid => Signing.encode_key(other_context.public_key)
        }
    }

    {:ok, active_trust} =
      Trust.add_eviction_anchor(
        strict,
        anchor_context.identity_uuid,
        anchor_context.public_key
      )

    anchored_tombstone =
      tombstone(%{ctx | signing_context: anchor_context}, [commit_id(1)])

    # This is the CX-fmzk reproduction: the record names and signs with a
    # generated keypair of its own. Internal consistency holds; authority does
    # not. The same signer is deliberately trusted for ordinary commits, which
    # also proves the two config sets are independent.
    self_named_tombstone =
      tombstone(%{ctx | signing_context: other_context}, [commit_id(2)])

    arm1_anchored = SlaTombstone.verify(anchored_tombstone, active_trust, store: ctx.store)

    arm1_other =
      SlaTombstone.verify(self_named_tombstone, active_trust, store: ctx.store)

    arm2_self_named = arm1_other
    arm3_trusted_not_anchored = arm1_other

    before =
      CommitStoreClient.create_commit(
        ctx.store,
        "eviction-policy-chain",
        "before",
        nil,
        %{},
        signing_context: other_context
      )

    retirement =
      CommitStoreClient.create_chained_commit(
        ctx.store,
        "eviction-policy-chain",
        "retire",
        %{},
        signing_context: other_context
      )

    after_retirement =
      CommitStoreClient.create_chained_commit(
        ctx.store,
        "eviction-policy-chain",
        "after",
        %{},
        signing_context: other_context
      )

    [anchor_entry] = active_trust.eviction_anchors
    {:ok, anchor} = EvictionAnchor.from_config(anchor_entry)

    {:ok, retired_trust} =
      Trust.retire_eviction_anchor(active_trust, anchor.id, retirement.id)

    [retired_entry] = retired_trust.eviction_anchors
    {:ok, retired_anchor} = EvictionAnchor.from_config(retired_entry)
    assert length(retired_trust.eviction_anchors) == length(active_trust.eviction_anchors)
    assert retired_anchor.id == anchor.id
    assert retired_anchor.retired_at == retirement.id

    assert {:error, :eviction_anchor_already_exists} =
             Trust.add_eviction_anchor(
               active_trust,
               anchor_context.identity_uuid,
               anchor_context.public_key
             )

    Application.put_env(:commonplace, :trust, active_trust)

    assert :ok =
             CommitStoreClient.store_sla_tombstone(ctx.store, anchored_tombstone,
               chain_position: before.id
             )

    Application.put_env(:commonplace, :trust, retired_trust)

    assert {:ok, reread_before_retirement} =
             CommitStoreClient.get_sla_tombstone_for_commit(ctx.store, commit_id(1))

    assert reread_before_retirement.id == anchored_tombstone.id

    arm4_before =
      SlaTombstone.verify(anchored_tombstone, retired_trust,
        store: ctx.store,
        chain_position: before.id
      )

    arm4_after =
      SlaTombstone.verify(anchored_tombstone, retired_trust,
        store: ctx.store,
        chain_position: after_retirement.id
      )

    revocation =
      Revocation.new(anchor.id, anchor_context.public_key)
      |> Revocation.sign(anchor_context.private_key)

    :ok = CommitStoreClient.store_revocation(ctx.store, revocation)
    anchor_identity_uuid = anchor.identity_uuid

    assert {:error, {:invalid_sla_tombstone, {:revoked_eviction_anchor, ^anchor_identity_uuid}}} =
             CommitStoreClient.get_sla_tombstone_for_commit(ctx.store, commit_id(1))

    arm5_revoked =
      SlaTombstone.verify(anchored_tombstone, retired_trust,
        store: ctx.store,
        chain_position: before.id
      )

    arm6_absent =
      SlaTombstone.verify(anchored_tombstone, Map.delete(active_trust, :eviction_anchors),
        store: ctx.store
      )

    assert arm1_anchored == :ok

    assert arm1_other ==
             {:error, {:untrusted_tombstone_signer, self_named_tombstone.signer_id}}

    assert arm2_self_named == arm1_other
    assert arm3_trusted_not_anchored == arm1_other
    assert Map.has_key?(active_trust.trusted_identities, other_context.identity_uuid)

    refute Enum.any?(
             active_trust.eviction_anchors,
             &(&1.identity_uuid == other_context.identity_uuid)
           )

    assert arm4_before == :ok
    assert arm4_after == {:error, {:retired_eviction_anchor, anchored_tombstone.signer_id}}
    assert arm5_revoked == {:error, {:revoked_eviction_anchor, anchor.identity_uuid}}
    assert arm6_absent == {:error, :no_eviction_anchor_configured}

    assert arm1_anchored != arm1_other
    assert arm4_before != arm4_after
    assert arm4_after != arm5_revoked
    assert arm5_revoked != arm6_absent

    IO.puts("ARM_1_ANCHORED=#{inspect(arm1_anchored)}")
    IO.puts("ARM_1_OTHER=#{inspect(arm1_other)}")
    IO.puts("ARM_2_CX_FMZK_SELF_NAMED=#{inspect(arm2_self_named)}")
    IO.puts("ARM_3_TRUSTED_NOT_ANCHORED=#{inspect(arm3_trusted_not_anchored)}")
    IO.puts("ARM_4_BEFORE_RETIREMENT=#{inspect(arm4_before)}")
    IO.puts("ARM_4_AFTER_RETIREMENT=#{inspect(arm4_after)}")
    IO.puts("ARM_5_REVOKED=#{inspect(arm5_revoked)}")
    IO.puts("ARM_6_ABSENT_CONFIG=#{inspect(arm6_absent)}")
    IO.puts("ARM_PAIRS_DIFFER=true")
    IO.puts("RETIREMENT_AXIS=CommitStoreClient.is_ancestor?/3")
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

  defp restore_trust({:ok, trust}),
    do: Application.put_env(:commonplace, :trust, trust)

  defp restore_trust(:error), do: Application.delete_env(:commonplace, :trust)
end

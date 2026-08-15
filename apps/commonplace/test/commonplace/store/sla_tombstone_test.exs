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

  test "store derives every position and public verification refuses evidence seams", ctx do
    tombstone = tombstone(ctx, [commit_id(90)])
    [anchor_entry] = ctx.trust.eviction_anchors
    {:ok, anchor} = EvictionAnchor.from_config(anchor_entry)

    refute function_exported?(CommitStoreClient, :store_sla_tombstone, 3)
    refute function_exported?(Trust, :retire_eviction_anchor, 3)
    assert :ok = CommitStoreClient.store_sla_tombstone(ctx.store, tombstone)

    assert {:ok, registration_position} =
             CommitStoreClient.get_sla_tombstone_position(ctx.store, tombstone.id)

    assert {:ok, activation_position} =
             CommitStoreClient.get_eviction_anchor_activation_position(ctx.store, anchor.id)

    assert {:ok, true} =
             CommitStoreClient.eviction_authority_position_before?(
               ctx.store,
               activation_position,
               registration_position
             )

    injected_position = commit_id(91)

    injected_result =
      SlaTombstone.verify(tombstone, ctx.trust,
        store: ctx.store,
        chain_position: injected_position,
        position_before?: fn _supplied_position, _supplied_retirement ->
          send(self(), :injected_relation_called)
          true
        end,
        revocation_fetcher: fn _anchor_id ->
          send(self(), :injected_revocation_fetcher_called)
          []
        end
      )

    assert injected_result ==
             {:error,
              {:unsupported_tombstone_verification_options,
               [:chain_position, :position_before?, :revocation_fetcher]}}

    refute_receive :injected_relation_called
    refute_receive :injected_revocation_fetcher_called
    assert :ok = SlaTombstone.verify(tombstone, ctx.trust, store: ctx.store)

    assert {:ok, retirement_position} =
             CommitStoreClient.retire_eviction_anchor(ctx.store, anchor.id)

    assert :ok = SlaTombstone.verify(tombstone, ctx.trust, store: ctx.store)

    assert {:ok, ^tombstone} =
             CommitStoreClient.get_sla_tombstone_for_commit(ctx.store, commit_id(90))

    # The public writer cannot create this state: a registration after
    # retirement is refused below. Mutate only the position index, then re-read
    # it, to prove the public verifier fails closed on at-retirement evidence.
    db = Commonplace.Store.CommitStore.db_handle(ctx.store)
    :ok = CubDB.put(db, {:sla_tombstone_position, tombstone.id}, retirement_position)

    assert {:ok, ^retirement_position} =
             CommitStoreClient.get_sla_tombstone_position(ctx.store, tombstone.id)

    at_retirement = SlaTombstone.verify(tombstone, ctx.trust, store: ctx.store)

    assert at_retirement ==
             {:error,
              {:tombstone_not_before_anchor_retirement, retirement_position, retirement_position}}

    refused_after_retirement =
      ctx
      |> tombstone([commit_id(92)])
      |> then(&CommitStoreClient.store_sla_tombstone(ctx.store, &1))

    assert {:error,
            {:invalid_sla_tombstone,
             {:eviction_anchor_already_retired, anchor_id, ^retirement_position}}} =
             refused_after_retirement

    assert anchor_id == anchor.id
    assert injected_result != :ok
    assert at_retirement != :ok

    IO.puts("CX_TADF_AFTER_WRITE_API_ARITY_3=false")
    IO.puts("CX_TADF_AFTER_RETIREMENT_API_ARITY_3=false")
    IO.puts("CX_TADF_AFTER_ACTIVATION_POSITION=#{Base.encode16(activation_position)}")
    IO.puts("CX_TADF_AFTER_REGISTRATION_POSITION=#{Base.encode16(registration_position)}")
    IO.puts("CX_TADF_AFTER_INJECTED_POSITION=#{Base.encode16(injected_position)}")
    IO.puts("CX_TADF_AFTER_INJECTED_EVIDENCE_RESULT=#{inspect(injected_result)}")
    IO.puts("CX_TADF_AFTER_RETIREMENT_POSITION=#{Base.encode16(retirement_position)}")
    IO.puts("CX_TADF_AFTER_HISTORICAL_VERIFY=:ok")
    IO.puts("CX_TADF_AFTER_AT_RETIREMENT_RESULT=#{inspect(at_retirement)}")
    IO.puts("CX_TADF_AFTER_REGISTRATION_REFUSAL=#{inspect(refused_after_retirement)}")
    IO.puts("CX_TADF_AFTER_ARM_PAIRS_DIFFER=true")
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

    Application.put_env(:commonplace, :trust, active_trust)
    assert :ok = CommitStoreClient.store_sla_tombstone(ctx.store, anchored_tombstone)

    arm1_anchored = SlaTombstone.verify(anchored_tombstone, active_trust, store: ctx.store)

    arm1_other =
      SlaTombstone.verify(self_named_tombstone, active_trust, store: ctx.store)

    arm2_self_named = arm1_other
    arm3_trusted_not_anchored = arm1_other

    [anchor_entry] = active_trust.eviction_anchors
    {:ok, anchor} = EvictionAnchor.from_config(anchor_entry)

    assert {:error, :eviction_anchor_already_exists} =
             Trust.add_eviction_anchor(
               active_trust,
               anchor_context.identity_uuid,
               anchor_context.public_key
             )

    assert {:ok, retirement_position} =
             CommitStoreClient.retire_eviction_anchor(ctx.store, anchor.id)

    assert {:ok, reread_before_retirement} =
             CommitStoreClient.get_sla_tombstone_for_commit(ctx.store, commit_id(1))

    assert reread_before_retirement.id == anchored_tombstone.id

    arm4_before =
      SlaTombstone.verify(anchored_tombstone, active_trust, store: ctx.store)

    arm4_after =
      ctx
      |> Map.put(:signing_context, anchor_context)
      |> tombstone([commit_id(3)])
      |> then(&CommitStoreClient.store_sla_tombstone(ctx.store, &1))

    revocation =
      Revocation.new(anchor.id, anchor_context.public_key)
      |> Revocation.sign(anchor_context.private_key)

    :ok = CommitStoreClient.store_revocation(ctx.store, revocation)
    anchor_identity_uuid = anchor.identity_uuid

    assert {:error, {:invalid_sla_tombstone, {:revoked_eviction_anchor, ^anchor_identity_uuid}}} =
             CommitStoreClient.get_sla_tombstone_for_commit(ctx.store, commit_id(1))

    arm5_revoked =
      SlaTombstone.verify(anchored_tombstone, active_trust, store: ctx.store)

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

    assert arm4_after ==
             {:error,
              {:invalid_sla_tombstone,
               {:eviction_anchor_already_retired, anchor.id, retirement_position}}}

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
    IO.puts("RETIREMENT_AXIS=EvictionAuthorityLedger.before?/3")
  end

  test "writer constructs a signed receipt that verifies and tampering fails", ctx do
    tombstone = tombstone(ctx, [commit_id(1), commit_id(2)])

    assert {:error, :eviction_anchor_activation_position_required} =
             SlaTombstone.verify(tombstone, ctx.trust, store: ctx.store)

    assert :ok = CommitStoreClient.store_sla_tombstone(ctx.store, tombstone)
    assert :ok = SlaTombstone.verify(tombstone, ctx.trust, store: ctx.store)

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

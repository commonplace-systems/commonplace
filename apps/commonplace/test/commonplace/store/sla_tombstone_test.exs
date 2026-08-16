defmodule Commonplace.Store.SlaTombstoneTest do
  @moduledoc """
  The twelve-arm ceremony rehearsal is copied from this file's earlier
  `six eviction-anchor acceptance arms differ by authority and chain position`
  rehearsal and its `store derives every position and public verification
  refuses evidence seams` proof. The distinct authority fixtures and explicit
  signing contexts come from the former; the restart-safe, store-owned position
  checks come from the latter. No downstream copy was found when this rehearsal
  was written.
  """

  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Projection
  alias Commonplace.Store.{Commit, CommitStoreClient, SlaTombstone}
  alias Commonplace.Trust
  alias Commonplace.Trust.{EvictionAnchor, Revocation}

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "sla_tombstone_#{System.unique_integer([:positive])}")

    nonce = System.unique_integer([:positive])
    store = :"sla_tombstone_store_#{nonce}"
    supervisor = :"sla_tombstone_supervisor_#{nonce}"

    start_supervised!(
      Supervisor.child_spec(
        {Commonplace.Store.Supervisor,
         data_dir: data_dir,
         name: supervisor,
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

    %{
      data_dir: data_dir,
      store: store,
      supervisor: supervisor,
      signing_context: signing_context,
      trust: trust
    }
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

  test "ceremony rehearsal prints twelve distinct acceptance arms from isolated state", ctx do
    anchor_context = fixture_signing_context("throwaway-eviction-anchor", 17)
    untrusted_context = fixture_signing_context("self-named-untrusted", 23)
    writer_context = fixture_signing_context("ordinary-writer-not-anchor", 29)
    preactivation_context = fixture_signing_context("preactivation-anchor", 31)

    strict = %{
      Trust.default_config()
      | accept_unsigned: false,
        trusted_identities: %{
          writer_context.identity_uuid => Signing.encode_key(writer_context.public_key)
        },
        eviction_anchors: []
    }

    {:ok, active_trust} =
      Trust.add_eviction_anchor(strict, anchor_context.identity_uuid, anchor_context.public_key)

    Application.put_env(:commonplace, :trust, active_trust)

    history_a =
      CommitStoreClient.create_commit(
        ctx.store,
        "ceremony-unrelated-history-a",
        <<1>>,
        nil,
        %{},
        signing_context: writer_context
      )

    history_b =
      CommitStoreClient.create_commit(
        ctx.store,
        "ceremony-unrelated-history-b",
        <<2>>,
        nil,
        %{},
        signing_context: writer_context
      )

    assert history_a.doc_uuid != history_b.doc_uuid
    assert history_a.parent_id != history_b.parent_id
    refute history_a.id == history_b.id
    refute history_a.parent_id == history_b.id
    refute history_b.parent_id == history_a.id

    assert {:ok, history_a_root} =
             CommitStoreClient.get_commit(ctx.store, history_a.parent_id)

    assert {:ok, history_b_root} =
             CommitStoreClient.get_commit(ctx.store, history_b.parent_id)

    assert is_nil(history_a_root.parent_id)
    assert is_nil(history_b_root.parent_id)
    refute history_a_root.id == history_b_root.id

    first = tombstone(%{ctx | signing_context: anchor_context}, [history_a.id])
    second = tombstone(%{ctx | signing_context: anchor_context}, [history_b.id])

    arm1 = CommitStoreClient.store_sla_tombstone(ctx.store, first)

    untrusted = tombstone(%{ctx | signing_context: untrusted_context}, [commit_id(2)])
    arm2_registration = CommitStoreClient.store_sla_tombstone(ctx.store, untrusted)

    arm2 = %{
      fixture: :self_named_untrusted,
      ordinary_write_authorization:
        Trust.authorized?(
          signed_commit(untrusted_context, "arm-2-ordinary-write"),
          :write,
          {:doc, "arm-2-ordinary-write"},
          strict
        ),
      registration: arm2_registration
    }

    trusted_writer = tombstone(%{ctx | signing_context: writer_context}, [commit_id(3)])
    arm3_registration = CommitStoreClient.store_sla_tombstone(ctx.store, trusted_writer)

    arm3 = %{
      fixture: :trusted_ordinary_writer_not_anchor,
      ordinary_write_authorization:
        Trust.authorized?(
          signed_commit(writer_context, "arm-3-ordinary-write"),
          :write,
          {:doc, "arm-3-ordinary-write"},
          strict
        ),
      registration: arm3_registration
    }

    arm2_3_differ =
      untrusted_context.identity_uuid != writer_context.identity_uuid and
        arm2.ordinary_write_authorization != arm3.ordinary_write_authorization

    identical_commit = signed_commit(anchor_context, "arm-4-identical-commit")
    permissive_before = Trust.default_config()

    {:ok, permissive_after} =
      Trust.add_eviction_anchor(
        permissive_before,
        anchor_context.identity_uuid,
        anchor_context.public_key
      )

    arm4_before =
      Trust.authorized?(
        identical_commit,
        :write,
        {:doc, identical_commit.doc_uuid},
        permissive_before
      )

    arm4_after =
      Trust.authorized?(
        identical_commit,
        :write,
        {:doc, identical_commit.doc_uuid},
        permissive_after
      )

    arm4 = %{
      identical_commit_id: Base.encode16(identical_commit.id),
      before_anchor_addition: arm4_before,
      after_anchor_addition: arm4_after
    }

    absent_trust = %{strict | eviction_anchors: []}
    Application.put_env(:commonplace, :trust, absent_trust)
    arm5 = CommitStoreClient.store_sla_tombstone(ctx.store, untrusted)
    Application.put_env(:commonplace, :trust, active_trust)

    assert :ok = CommitStoreClient.store_sla_tombstone(ctx.store, second)

    assert {:ok, first_position} =
             CommitStoreClient.get_sla_tombstone_position(ctx.store, first.id)

    arm6 = {:store_assigned_position, Base.encode16(first_position)}

    assert {:ok, second_position} =
             CommitStoreClient.get_sla_tombstone_position(ctx.store, second.id)

    [anchor_entry] = active_trust.eviction_anchors
    {:ok, anchor} = EvictionAnchor.from_config(anchor_entry)

    assert {:ok, retirement_position} =
             CommitStoreClient.retire_eviction_anchor(ctx.store, anchor.id)

    old_store_pid = Process.whereis(ctx.store)
    restart_ref = Process.monitor(old_store_pid)
    Process.exit(old_store_pid, :kill)
    assert_receive {:DOWN, ^restart_ref, :process, ^old_store_pid, :killed}
    _ = :sys.get_state(ctx.supervisor)
    restarted_store_pid = Process.whereis(ctx.store)
    assert is_pid(restarted_store_pid)
    refute restarted_store_pid == old_store_pid
    _ = :sys.get_state(restarted_store_pid)

    arm7 = SlaTombstone.verify(first, active_trust, store: ctx.store)

    after_retirement =
      tombstone(%{ctx | signing_context: anchor_context}, [commit_id(8)])

    arm8 = CommitStoreClient.store_sla_tombstone(ctx.store, after_retirement)

    arm9_relation =
      CommitStoreClient.eviction_authority_position_before?(
        ctx.store,
        first_position,
        second_position
      )

    arm9 = %{
      histories: {history_a.doc_uuid, history_b.doc_uuid},
      parent_ids: {history_a.parent_id, history_b.parent_id},
      registration_positions: {Base.encode16(first_position), Base.encode16(second_position)},
      first_before_second: arm9_relation,
      first_verifies_after_retirement: SlaTombstone.verify(first, active_trust, store: ctx.store),
      second_verifies_after_retirement:
        SlaTombstone.verify(second, active_trust, store: ctx.store)
    }

    preactivation =
      tombstone(%{ctx | signing_context: preactivation_context}, [commit_id(10)])

    Application.put_env(:commonplace, :trust, strict)
    arm10_before_activation = CommitStoreClient.store_sla_tombstone(ctx.store, preactivation)

    {:ok, preactivation_trust} =
      Trust.add_eviction_anchor(
        strict,
        preactivation_context.identity_uuid,
        preactivation_context.public_key
      )

    Application.put_env(:commonplace, :trust, preactivation_trust)

    arm10_after_anchor_addition =
      SlaTombstone.verify(preactivation, preactivation_trust, store: ctx.store)

    arm10_production_registration_after_anchor_addition =
      CommitStoreClient.store_sla_tombstone(ctx.store, preactivation)

    arm10 = %{
      registration_before_activation: arm10_before_activation,
      verification_after_anchor_addition: arm10_after_anchor_addition,
      production_registration_after_anchor_addition:
        arm10_production_registration_after_anchor_addition
    }

    Application.put_env(:commonplace, :trust, active_trust)

    isolated_tombstone_reread =
      case CommitStoreClient.get_sla_tombstone_for_commit(ctx.store, history_a.id) do
        {:ok, %SlaTombstone{id: id}} -> id == first.id
        _other -> false
      end

    revocation =
      Revocation.new(anchor.id, anchor_context.public_key)
      |> Revocation.sign(anchor_context.private_key)

    :ok = CommitStoreClient.store_revocation(ctx.store, revocation)

    arm11_retirement = arm8
    arm11_revocation = SlaTombstone.verify(first, active_trust, store: ctx.store)
    arm11 = %{retirement: arm11_retirement, revocation: arm11_revocation}

    isolated_commits_dir = Path.join(ctx.data_dir, "commits")

    arm12 = %{
      isolated_data_dir: ctx.data_dir,
      isolated_commits_dir: isolated_commits_dir,
      live_commits_dir: "/home/jes/commonplace/workspace/.commonplace/commits",
      paths_distinct:
        Path.expand(isolated_commits_dir) !=
          "/home/jes/commonplace/workspace/.commonplace/commits",
      first_tombstone_reread_from_isolated_store: isolated_tombstone_reread
    }

    assert arm1 == :ok

    assert arm2_registration ==
             {:error,
              {:invalid_sla_tombstone, {:untrusted_tombstone_signer, untrusted.signer_id}}}

    assert arm3.ordinary_write_authorization == :ok

    assert arm3_registration ==
             {:error,
              {:invalid_sla_tombstone, {:untrusted_tombstone_signer, trusted_writer.signer_id}}}

    assert arm2_3_differ
    assert arm4_before == arm4_after
    assert arm4_before == :ok
    assert arm5 == {:error, {:invalid_sla_tombstone, :no_eviction_anchor_configured}}
    assert arm7 == :ok

    assert arm8 ==
             {:error,
              {:invalid_sla_tombstone,
               {:eviction_anchor_already_retired, anchor.id, retirement_position}}}

    assert arm9_relation == {:ok, true}
    assert arm9.first_verifies_after_retirement == :ok
    assert arm9.second_verifies_after_retirement == :ok

    assert arm10_before_activation ==
             {:error, {:invalid_sla_tombstone, :no_eviction_anchor_configured}}

    assert arm10_after_anchor_addition == {:error, :eviction_anchor_activation_position_required}
    assert arm10_production_registration_after_anchor_addition == :ok
    assert arm10_before_activation != arm10_production_registration_after_anchor_addition

    assert arm11_revocation ==
             {:error, {:revoked_eviction_anchor, anchor_context.identity_uuid}}

    assert arm11_retirement != arm11_revocation
    assert arm12.paths_distinct
    assert arm12.first_tombstone_reread_from_isolated_store

    IO.puts("EVICTION_CEREMONY_ARM_1=#{inspect(arm1)}")
    IO.puts("EVICTION_CEREMONY_ARM_2=#{inspect(arm2)}")
    IO.puts("EVICTION_CEREMONY_ARM_3=#{inspect(arm3)}")
    IO.puts("EVICTION_CEREMONY_ARM_4=#{inspect(arm4)}")
    IO.puts("EVICTION_CEREMONY_ARM_5=#{inspect(arm5)}")
    IO.puts("EVICTION_CEREMONY_ARM_6=#{inspect(arm6)}")
    IO.puts("EVICTION_CEREMONY_ARM_7=#{inspect(arm7)}")
    IO.puts("EVICTION_CEREMONY_ARM_8=#{inspect(arm8)}")
    IO.puts("EVICTION_CEREMONY_ARM_9=#{inspect(arm9)}")
    IO.puts("EVICTION_CEREMONY_ARM_10=#{inspect(arm10)}")
    IO.puts("EVICTION_CEREMONY_ARM_11=#{inspect(arm11)}")
    IO.puts("EVICTION_CEREMONY_ARM_12=#{inspect(arm12)}")
    IO.puts("EVICTION_CEREMONY_PAIR_2_3_DIFFER=#{inspect(arm2_3_differ)}")
    IO.puts("EVICTION_CEREMONY_PAIR_4_AUTHORIZATION_SAME=#{inspect(arm4_before == arm4_after)}")

    IO.puts(
      "EVICTION_CEREMONY_PAIR_10_PRE_POST_DIFFER=#{inspect(arm10_before_activation != arm10_production_registration_after_anchor_addition)}"
    )

    IO.puts(
      "EVICTION_CEREMONY_PAIR_11_RETIREMENT_REVOCATION_DIFFER=#{inspect(arm11_retirement != arm11_revocation)}"
    )
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

  defp signed_commit(signing_context, doc_uuid) do
    signer_id =
      Signing.signer_id(signing_context.identity_uuid, signing_context.public_key)

    doc_uuid
    |> Commit.new("ceremony-write", nil)
    |> Signing.sign_commit(signing_context.private_key, signer_id)
  end

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

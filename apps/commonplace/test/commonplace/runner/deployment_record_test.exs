defmodule Commonplace.Runner.DeploymentRecordTest do
  @moduledoc """
  I4's fixture is copied from I3's `ClassRatificationTest`, which was copied
  from I2's `SpawnCeremonyTest`, which was copied from I1's
  `RootScopeGateTest`, which was copied from `Trust.SubtreeCarveTest`.

  It keeps the isolated enforcing store and explicit fixture signing context.
  The eviction is synthetic only at the commit-availability seam: the
  tombstone is a real `SlaTombstone`, signed, stored, and verified. The
  never-written arm uses a distinct random commit id with no tombstone.
  """

  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Document.DocRef
  alias Commonplace.Runner.DeploymentRecord
  alias Commonplace.Store.{Commit, CommitStoreClient, SlaTombstone}
  alias Commonplace.Trust

  setup do
    data_dir = Path.join(System.tmp_dir!(), "cp_i4_deployment_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(data_dir)
    n = :rand.uniform(1_000_000_000)
    store = :"i4_deployment_store_#{n}"
    runner = signing_context("fixture-runner")
    prior_trust = Application.fetch_env(:commonplace, :trust)

    {:ok, trust_config} =
      Trust.add_eviction_anchor(
        %{
          accept_unsigned: false,
          trusted_identities: %{
            runner.identity_uuid => Signing.encode_key(runner.public_key)
          },
          eviction_anchors: []
        },
        runner.identity_uuid,
        runner.public_key
      )

    Application.put_env(:commonplace, :trust, trust_config)

    File.write!(
      Path.join(data_dir, "trust.json"),
      Jason.encode!(%{
        "accept_unsigned" => false,
        "trusted_identities" => %{
          runner.identity_uuid => Signing.encode_key(runner.public_key)
        },
        "eviction_anchors" => trust_config.eviction_anchors
      })
    )

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: data_dir,
       name: :"i4_deployment_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"i4_deployment_tss_#{n}",
       pending_imports_name: :"i4_deployment_pi_#{n}",
       local_write_gate: :enforce}
    )

    on_exit(fn ->
      File.rm_rf!(data_dir)
      restore_trust(prior_trust)
    end)

    %{log_uuid: UUID.uuid4(), runner: runner, store: store, trust_config: trust_config}
  end

  test "runner appends complete records and confirms the landed sequence by re-read", ctx do
    first = record("deployment-a")
    second = record("deployment-b")

    assert {:ok, first_write} =
             DeploymentRecord.append(ctx.log_uuid, first,
               store: ctx.store,
               signing_context: ctx.runner
             )

    assert {:ok, second_write} =
             DeploymentRecord.append(ctx.log_uuid, second,
               store: ctx.store,
               signing_context: ctx.runner
             )

    assert {:ok, reread} = DeploymentRecord.read(ctx.log_uuid, ctx.store)
    assert reread == [stringify_keys(first), stringify_keys(second)]

    assert {:ok, second_commit} = CommitStoreClient.get_commit(ctx.store, second_write.commit_id)
    assert second_commit.parent_id == first_write.commit_id
    assert second_commit.metadata.sla == DeploymentRecord.ephemeral_sla()
    assert :ok = Signing.verify_commit(second_commit, ctx.runner.public_key)

    IO.puts("DEPLOYMENT_REREAD_OUTCOME=#{inspect(reread)}")
    IO.puts("DEPLOYMENT_LOG_SLA=#{inspect(second_commit.metadata.sla)}")
  end

  test "unpinned deployment and promotion references are refused at the read boundary", ctx do
    unpinned = DocRef.new(UUID.uuid4(), path: "yield.json")
    bad_record = put_in(record("deployment-unpinned"), [:yields], [DocRef.to_string(unpinned)])

    assert {:error, :pinned_deployment_reference_required} =
             DeploymentRecord.append(ctx.log_uuid, bad_record,
               store: ctx.store,
               signing_context: ctx.runner
             )

    assert {:error, :promotion_version_required} =
             DeploymentRecord.read_promoted(unpinned, ctx.store)
  end

  test "durable yield survives simulated log eviction and all three range outcomes differ", ctx do
    deployment_id = "deployment-evicted"
    yield_value = %{"next_step" => "inspect the pinned incident artifact", "priority" => 2}

    assert {:ok, yield_ref} =
             DeploymentRecord.promote(
               :yield,
               deployment_id,
               yield_value,
               "__identities__/platform-watch/yields/incident.json",
               store: ctx.store,
               signing_context: ctx.runner
             )

    deployment =
      record(deployment_id)
      |> Map.put(:yields, [DocRef.to_string(yield_ref)])

    assert {:ok, write} =
             DeploymentRecord.append(ctx.log_uuid, deployment,
               store: ctx.store,
               signing_context: ctx.runner
             )

    assert {:ok, %Commit{} = deployment_commit} =
             CommitStoreClient.get_commit(ctx.store, write.commit_id)

    assert {:ok, tombstone} =
             SlaTombstone.new(
               %{
                 subtree_id: ctx.log_uuid,
                 sla: DeploymentRecord.ephemeral_sla(),
                 commit_ids: [deployment_commit.id],
                 evicted_at: "2026-08-15T12:00:00Z",
                 dropped_hash: :crypto.hash(:sha256, deployment_commit.update)
               },
               ctx.runner
             )

    assert :ok = CommitStoreClient.store_sla_tombstone(ctx.store, tombstone)

    signature_verification =
      SlaTombstone.verify(tombstone, ctx.trust_config, store: ctx.store)

    assert signature_verification == :ok

    simulate_unavailable = fn _commit_id -> :none end

    assert {:error, {:invalid_tombstone, :no_eviction_anchor_configured}} =
             DeploymentRecord.range_status(ctx.log_uuid, deployment_commit.id, ctx.store,
               commit_fetcher: simulate_unavailable,
               trust_config: Map.delete(ctx.trust_config, :eviction_anchors)
             )

    evicted =
      DeploymentRecord.range_status(ctx.log_uuid, deployment_commit.id, ctx.store,
        commit_fetcher: simulate_unavailable,
        trust_config: ctx.trust_config
      )

    never_written_id = :crypto.strong_rand_bytes(32)

    never_written =
      DeploymentRecord.range_status(ctx.log_uuid, never_written_id, ctx.store,
        commit_fetcher: simulate_unavailable
      )

    present = DeploymentRecord.range_status(ctx.log_uuid, deployment_commit.id, ctx.store)
    promoted_after_eviction = DeploymentRecord.read_promoted(yield_ref, ctx.store)

    assert {:evicted_per_policy, %{tombstone_id: tombstone_id}} = evicted
    assert tombstone_id == tombstone.id

    assert {:absent_without_tombstone,
            %{
              commit_id: ^never_written_id,
              possible_causes: [:never_written, :lost]
            }} = never_written

    assert {:present, %{commit_id: deployment_commit_id}} = present
    assert deployment_commit_id == deployment_commit.id

    assert {:ok,
            %{
              "deployment_id" => ^deployment_id,
              "kind" => "yield",
              "value" => ^yield_value
            }} = promoted_after_eviction

    assert MapSet.size(MapSet.new([evicted, never_written, present])) == 3

    IO.puts("TOMBSTONE_SIGNATURE_CALL=SlaTombstone.verify(tombstone)")
    IO.puts("TOMBSTONE_SIGNATURE_RESULT=#{inspect(signature_verification)}")
    IO.puts("EVICTED_RANGE_OUTCOME=#{inspect(evicted)}")
    IO.puts("NEVER_WRITTEN_RANGE_CONSTRUCTION=#{Base.encode16(never_written_id, case: :lower)}")
    IO.puts("NEVER_WRITTEN_RANGE_OUTCOME=#{inspect(never_written)}")
    IO.puts("PRESENT_RANGE_OUTCOME=#{inspect(present)}")
    IO.puts("THREE_WAY_DISCRIMINATION=#{inspect([evicted, never_written, present])}")
    IO.puts("PROMOTED_YIELD_AFTER_EVICTION=#{inspect(promoted_after_eviction)}")
  end

  test "reader refuses tampered and validly self-signed forged tombstones", ctx do
    commit_id = :crypto.strong_rand_bytes(32)

    assert {:ok, tombstone} =
             SlaTombstone.new(
               %{
                 subtree_id: ctx.log_uuid,
                 sla: DeploymentRecord.ephemeral_sla(),
                 commit_ids: [commit_id],
                 evicted_at: "2026-08-15T12:00:00Z",
                 dropped_hash: :crypto.hash(:sha256, "forged-range")
               },
               ctx.runner
             )

    tampered = %{tombstone | signature: :binary.copy(<<0>>, 64)}

    tampered_refusal =
      DeploymentRecord.range_status(ctx.log_uuid, commit_id, ctx.store,
        commit_fetcher: fn _ -> :none end,
        tombstone_fetcher: fn _ -> {:ok, tampered} end,
        trust_config: ctx.trust_config
      )

    assert tampered_refusal == {:error, {:invalid_tombstone, :invalid_signature}}

    attacker = signing_context("untrusted-evictor")

    assert {:ok, forged} =
             SlaTombstone.new(
               %{
                 subtree_id: ctx.log_uuid,
                 sla: DeploymentRecord.ephemeral_sla(),
                 commit_ids: [commit_id],
                 evicted_at: "2026-08-15T12:00:00Z",
                 dropped_hash: :crypto.hash(:sha256, "forged-range")
               },
               attacker
             )

    assert SlaTombstone.verify(forged) ==
             {:error, {:untrusted_tombstone_signer, forged.signer_id}}

    forged_refusal =
      DeploymentRecord.range_status(ctx.log_uuid, commit_id, ctx.store,
        commit_fetcher: fn _ -> :none end,
        tombstone_fetcher: fn _ -> {:ok, forged} end,
        trust_config: ctx.trust_config
      )

    assert forged_refusal ==
             {:error, {:invalid_tombstone, {:untrusted_tombstone_signer, forged.signer_id}}}

    IO.puts("TAMPERED_TOMBSTONE_REFUSAL=#{inspect(tampered_refusal)}")
    IO.puts("FORGED_TOMBSTONE_VERIFICATION=#{inspect(SlaTombstone.verify(forged))}")
    IO.puts("FORGED_TOMBSTONE_REFUSAL=#{inspect(forged_refusal)}")
  end

  defp record(deployment_id) do
    ref = pinned_ref()

    %{
      ask_ref: ref,
      budget: %{tokens: 1_000, money: 2.5, wall_seconds: 300},
      capability_proofs: [String.duplicate("a", 64)],
      cell_manifest_ref: ref,
      class_ref: ref,
      context_inputs: [ref],
      decision_refs: [],
      deployment_id: deployment_id,
      ended_at: "2026-08-15T12:05:00Z",
      finding_refs: [],
      identity_ref: ref,
      outputs: [],
      runtime_profile: %{
        model: "fixture-model",
        sandbox_profile: String.duplicate("b", 64),
        tools_hash: String.duplicate("c", 64)
      },
      started_at: "2026-08-15T12:00:00Z",
      yields: []
    }
  end

  defp pinned_ref do
    DocRef.new(UUID.uuid4(),
      path: "fixture.json",
      cid: Base.encode16(:crypto.strong_rand_bytes(32))
    )
    |> DocRef.to_string()
  end

  defp signing_context(identity_uuid) do
    {public_key, private_key} = Signing.generate_keypair()

    %SigningContext{
      identity_uuid: identity_uuid,
      public_key: public_key,
      private_key: private_key
    }
  end

  defp restore_trust({:ok, trust}), do: Application.put_env(:commonplace, :trust, trust)

  defp restore_trust(:error), do: Application.delete_env(:commonplace, :trust)

  defp stringify_keys(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(map) when is_map(map), do: stringify_keys(map)
  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end

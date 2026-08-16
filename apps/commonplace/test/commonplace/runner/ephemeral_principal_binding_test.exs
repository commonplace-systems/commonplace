defmodule Commonplace.Runner.EphemeralPrincipalBindingTest do
  @moduledoc """
  The deployment-record fixture is copied from I4's `DeploymentRecordTest`.
  No key-custody or joining claim is exercised here: fixture signing contexts
  supply the short-lived keys directly.
  """

  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Document.DocRef
  alias Commonplace.Runner.DeploymentRecord
  alias Commonplace.Store.Commit

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "cp_ephemeral_binding_#{:rand.uniform(1_000_000_000)}")

    File.mkdir_p!(data_dir)
    n = :rand.uniform(1_000_000_000)
    store = :"ephemeral_binding_store_#{n}"
    recorder = signing_context("fixture-recorder")

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: data_dir,
       name: :"ephemeral_binding_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"ephemeral_binding_tss_#{n}",
       pending_imports_name: :"ephemeral_binding_pi_#{n}"}
    )

    on_exit(fn -> File.rm_rf!(data_dir) end)

    %{log_uuid: UUID.uuid4(), recorder: recorder, store: store}
  end

  test "arm 1: a signed commit resolves to its durable identity through the reread record", ctx do
    durable_identity = UUID.uuid4()
    worker = signing_context(UUID.uuid4())
    commit = signed_commit(worker)
    deployment = record("deployment-one", commit.signer_id, durable_identity)

    assert {:ok, _write} = append(ctx, deployment)
    assert {:ok, [reread]} = DeploymentRecord.read(ctx.log_uuid, ctx.store)
    assert reread["signer_id"] == commit.signer_id

    assert {:ok, ^durable_identity} =
             DeploymentRecord.resolve_signer(commit, ctx.log_uuid, ctx.store)
  end

  test "arm 2: two deployments retain different signers and resolve to one durable identity",
       ctx do
    durable_identity = UUID.uuid4()
    first_worker = signing_context(UUID.uuid4())
    second_worker = signing_context(UUID.uuid4())
    first_commit = signed_commit(first_worker)
    second_commit = signed_commit(second_worker)

    assert {:ok, _write} =
             append(ctx, record("deployment-first", first_commit.signer_id, durable_identity))

    assert {:ok, _write} =
             append(ctx, record("deployment-second", second_commit.signer_id, durable_identity))

    assert first_commit.signer_id != second_commit.signer_id

    assert {:ok, ^durable_identity} =
             DeploymentRecord.resolve_signer(first_commit, ctx.log_uuid, ctx.store)

    assert {:ok, ^durable_identity} =
             DeploymentRecord.resolve_signer(second_commit, ctx.log_uuid, ctx.store)
  end

  test "arm 3: a signed ephemeral principal without a record gets a named nonempty-lookup refusal",
       ctx do
    durable_identity = UUID.uuid4()
    recorded_worker = signing_context(UUID.uuid4())
    unrecorded_worker = signing_context(UUID.uuid4())
    recorded_commit = signed_commit(recorded_worker)
    unrecorded_commit = signed_commit(unrecorded_worker)

    assert {:ok, _write} =
             append(
               ctx,
               record("deployment-recorded", recorded_commit.signer_id, durable_identity)
             )

    assert {:ok, records} = DeploymentRecord.read(ctx.log_uuid, ctx.store)
    assert records != []
    refute Enum.any?(records, &(&1["signer_id"] == unrecorded_commit.signer_id))
    assert is_binary(unrecorded_commit.signature)

    no_record =
      DeploymentRecord.resolve_signer(unrecorded_commit, ctx.log_uuid, ctx.store)

    assert no_record == {:error, :ephemeral_principal_deployment_not_found}

    empty_log_uuid = UUID.uuid4()

    assert {:ok, []} = DeploymentRecord.read(empty_log_uuid, ctx.store)

    empty_lookup =
      DeploymentRecord.resolve_signer(unrecorded_commit, empty_log_uuid, ctx.store)

    assert empty_lookup == {:error, :deployment_record_lookup_empty}
    assert no_record != empty_lookup

    assert {:ok, ^durable_identity} =
             DeploymentRecord.resolve_signer(recorded_commit, ctx.log_uuid, ctx.store)
  end

  test "arm 4: a record naming a principal that never signed is refused", ctx do
    durable_identity = UUID.uuid4()
    never_signing_worker = signing_context(UUID.uuid4())

    signer_id =
      Signing.signer_id(never_signing_worker.identity_uuid, never_signing_worker.public_key)

    assert {:ok, _write} =
             append(ctx, record("deployment-never-signed", signer_id, durable_identity))

    unsigned_commit = %{Commit.new(UUID.uuid4(), "unsigned worker output") | signer_id: signer_id}

    assert {:ok, records} = DeploymentRecord.read(ctx.log_uuid, ctx.store)
    assert Enum.any?(records, &(&1["signer_id"] == signer_id))
    assert unsigned_commit.signer_id == signer_id
    assert unsigned_commit.signature == nil

    assert {:error, :ephemeral_principal_has_no_signed_commit} =
             DeploymentRecord.resolve_signer(unsigned_commit, ctx.log_uuid, ctx.store)
  end

  defp append(ctx, deployment) do
    DeploymentRecord.append(ctx.log_uuid, deployment,
      store: ctx.store,
      signing_context: ctx.recorder
    )
  end

  defp record(deployment_id, signer_id, durable_identity) do
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
      identity_ref: pinned_ref(durable_identity),
      outputs: [],
      runtime_profile: %{
        model: "fixture-model",
        sandbox_profile: String.duplicate("b", 64),
        tools_hash: String.duplicate("c", 64)
      },
      signer_id: signer_id,
      started_at: "2026-08-15T12:00:00Z",
      yields: []
    }
  end

  defp signed_commit(worker) do
    Commit.new(UUID.uuid4(), "signed worker output")
    |> Signing.sign_commit(
      worker.private_key,
      Signing.signer_id(worker.identity_uuid, worker.public_key)
    )
  end

  defp pinned_ref(uuid \\ UUID.uuid4()) do
    DocRef.new(uuid,
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
end

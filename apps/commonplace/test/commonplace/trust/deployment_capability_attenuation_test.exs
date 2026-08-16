defmodule Commonplace.Trust.DeploymentCapabilityAttenuationTest do
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.MUD.{Schemas, World}
  alias Commonplace.Store.{CommitStoreClient, Commit}
  alias Commonplace.Trust
  alias Commonplace.Trust.{Capability, VerifyChain}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_deployment_cap_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"deployment_cap_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"deployment_cap_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"deployment_cap_tss_#{n}",
       pending_imports_name: :"deployment_cap_pi_#{n}"}
    )

    root_ctx = signing_context(UUID.uuid4())
    durable_identity = UUID.uuid4()
    cell_ctx = signing_context(durable_identity)
    deployment_ctx = signing_context(durable_identity)

    old = %{
      data_dir: Application.get_env(:commonplace, :data_dir),
      trust: Application.get_env(:commonplace, :trust),
      gate: Application.get_env(:commonplace, :local_write_gate)
    }

    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :trust, trust_config(root_ctx))
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    on_exit(fn ->
      for {key, value} <- old do
        app_key = %{data_dir: :data_dir, trust: :trust, gate: :local_write_gate}[key]

        if is_nil(value),
          do: Application.delete_env(:commonplace, app_key),
          else: Application.put_env(:commonplace, app_key, value)
      end

      File.rm_rf!(dir)
    end)

    {:ok, room} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Schemas.Room{name: "Room", description: "deployment target"}),
        store,
        signing_context: root_ctx
      )

    subtree_root = UUID.uuid4()

    :ok =
      World.set_meta(room, Schemas.room_filename(), "zone", subtree_root, store,
        signing_context: root_ctx
      )

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      store: store,
      root_ctx: root_ctx,
      durable_identity: durable_identity,
      cell_ctx: cell_ctx,
      deployment_ctx: deployment_ctx,
      room: room,
      subtree_root: subtree_root,
      parent_not_before: DateTime.add(now, -3_600, :second),
      parent_not_after: DateTime.add(now, 3_600, :second),
      child_not_before: DateTime.add(now, -1_800, :second),
      child_not_after: DateTime.add(now, 1_800, :second)
    }
  end

  test "arm 1: same-root deployment with subset verbs and a tighter expiry mints and verifies",
       ctx do
    cell = mint_cell!(ctx)
    deployment_claim = deployment_claim(ctx)

    assert same_root?(deployment_claim, cell.claim) and
             verbs_subset?(deployment_claim, cell.claim) and
             window_within?(deployment_claim, cell.claim)

    assert {:ok, deployment} =
             Capability.issue(
               ctx.cell_ctx,
               keyed(ctx.deployment_ctx),
               deployment_claim,
               cell.id,
               parent: cell
             )

    :ok = store_capabilities(ctx.store, [cell, deployment])

    assert capability_present?(ctx.store, cell.id) and
             capability_present?(ctx.store, deployment.id)

    verification = VerifyChain.verify_chain(deployment.id, anchors(ctx), ctx.store)

    assert {:ok, effective} = verification
    assert effective.verbs == [:write]
    assert effective.scope == {:subtree, ctx.subtree_root}
    assert effective.caveats.not_after == ctx.child_not_after
  end

  test "arm 2: a deployment expiry looser than the cell expiry is not minted", ctx do
    cell = mint_cell!(ctx)

    deployment_claim =
      deployment_claim(ctx,
        not_after: DateTime.add(ctx.parent_not_after, 1, :second)
      )

    assert same_root?(deployment_claim, cell.claim) and
             verbs_subset?(deployment_claim, cell.claim) and
             DateTime.compare(
               deployment_claim.caveats.not_after,
               cell.claim.caveats.not_after
             ) == :gt

    assert {:error, {:not_attenuation, :child_exceeds_parent}} =
             Capability.issue(
               ctx.cell_ctx,
               keyed(ctx.deployment_ctx),
               deployment_claim,
               cell.id,
               parent: cell
             )
  end

  test "arm 3: a different subtree root is refused by the explicit mint-time equality", ctx do
    cell = mint_cell!(ctx)
    deployment_claim = %{deployment_claim(ctx) | scope: {:subtree, UUID.uuid4()}}

    assert not same_root?(deployment_claim, cell.claim) and
             Capability.attenuates?(deployment_claim, cell.claim)

    assert {:error, :subtree_scope_root_mismatch} =
             Capability.issue(
               ctx.cell_ctx,
               keyed(ctx.deployment_ctx),
               deployment_claim,
               cell.id,
               parent: cell
             )
  end

  test "arm 4: a deployment cannot add a verb absent from its cell", ctx do
    cell = mint_cell!(ctx)
    deployment_claim = %{deployment_claim(ctx) | verbs: [:write, :execute]}

    assert same_root?(deployment_claim, cell.claim) and
             :execute in deployment_claim.verbs and
             :execute not in cell.claim.verbs and
             window_within?(deployment_claim, cell.claim)

    assert {:error, {:not_attenuation, :child_exceeds_parent}} =
             Capability.issue(
               ctx.cell_ctx,
               keyed(ctx.deployment_ctx),
               deployment_claim,
               cell.id,
               parent: cell
             )
  end

  test "arm 5: a child of a cell lacking delegate is refused at mint and verify", ctx do
    cell = mint_cell!(ctx, verbs: [:write])
    deployment_claim = deployment_claim(ctx)

    assert :delegate not in cell.claim.verbs and
             same_root?(deployment_claim, cell.claim) and
             verbs_subset?(deployment_claim, cell.claim) and
             window_within?(deployment_claim, cell.claim)

    assert {:error, :delegation_not_permitted} =
             Capability.issue(
               ctx.cell_ctx,
               keyed(ctx.deployment_ctx),
               deployment_claim,
               cell.id,
               parent: cell
             )

    deployment =
      ctx.cell_ctx
      |> keyed()
      |> Capability.new(keyed(ctx.deployment_ctx), deployment_claim, cell.id)
      |> Capability.sign(ctx.cell_ctx.private_key)

    :ok = store_capabilities(ctx.store, [cell, deployment])

    assert :delegate not in cell.claim.verbs and
             capability_present?(ctx.store, cell.id) and
             capability_present?(ctx.store, deployment.id)

    assert {:error, :delegation_not_permitted} =
             VerifyChain.verify_chain(deployment.id, anchors(ctx), ctx.store)
  end

  test "arm 6: an expired deployment key write is declined specifically as expired", ctx do
    cell = mint_cell!(ctx)

    expired_at = DateTime.add(DateTime.utc_now() |> DateTime.truncate(:second), -1, :second)
    deployment_claim = deployment_claim(ctx, not_after: expired_at)

    assert same_root?(deployment_claim, cell.claim) and
             window_within?(deployment_claim, cell.claim)

    assert {:ok, deployment} =
             Capability.issue(
               ctx.cell_ctx,
               keyed(ctx.deployment_ctx),
               deployment_claim,
               cell.id,
               parent: cell
             )

    :ok = store_capabilities(ctx.store, [cell, deployment])

    assert DateTime.compare(DateTime.utc_now(), deployment.claim.caveats.not_after) == :gt and
             deployment.audience == keyed(ctx.deployment_ctx) and
             capability_present?(ctx.store, deployment.id)

    assert {:error, {:trust_rejected, :expired}} =
             World.set_meta(
               ctx.room,
               Schemas.room_filename(),
               "description",
               "expired deployment write",
               ctx.store,
               signing_context: ctx.deployment_ctx,
               cert_cids: [deployment.id]
             )
  end

  test "arm 7: cell and deployment commits have different signers and one durable identity",
       ctx do
    cell = mint_cell!(ctx)
    deployment_claim = deployment_claim(ctx)

    assert ctx.cell_ctx.identity_uuid == ctx.durable_identity and
             ctx.deployment_ctx.identity_uuid == ctx.durable_identity and
             ctx.cell_ctx.public_key != ctx.deployment_ctx.public_key

    assert {:ok, deployment} =
             Capability.issue(
               ctx.cell_ctx,
               keyed(ctx.deployment_ctx),
               deployment_claim,
               cell.id,
               parent: cell
             )

    :ok = store_capabilities(ctx.store, [cell, deployment])
    {:ok, target} = World.meta_doc_uuid(ctx.room, Schemas.room_filename(), ctx.store)
    cfg = trust_config(ctx.root_ctx)

    assert Trust.writer_authorized?(
             ctx.cell_ctx.identity_uuid,
             ctx.cell_ctx.public_key,
             [cell.id],
             target,
             cfg,
             ctx.store
           )

    assert :ok =
             World.set_meta(
               ctx.room,
               Schemas.room_filename(),
               "description",
               "cell write",
               ctx.store,
               signing_context: ctx.cell_ctx,
               cert_cids: [cell.id]
             )

    assert {:ok, %Commit{} = cell_commit} = CommitStoreClient.latest_commit(ctx.store, target)

    assert Trust.writer_authorized?(
             ctx.deployment_ctx.identity_uuid,
             ctx.deployment_ctx.public_key,
             [deployment.id],
             target,
             cfg,
             ctx.store
           )

    assert :ok =
             World.set_meta(
               ctx.room,
               Schemas.room_filename(),
               "description",
               "deployment write",
               ctx.store,
               signing_context: ctx.deployment_ctx,
               cert_cids: [deployment.id]
             )

    assert {:ok, %Commit{} = deployment_commit} =
             CommitStoreClient.latest_commit(ctx.store, target)

    assert cell_commit.signer_id != deployment_commit.signer_id
    assert :ok = Signing.verify_commit(cell_commit, ctx.cell_ctx.public_key)

    assert {:error, :invalid_signature} =
             Signing.verify_commit(cell_commit, ctx.deployment_ctx.public_key)

    assert :ok = Signing.verify_commit(deployment_commit, ctx.deployment_ctx.public_key)

    assert {:error, :invalid_signature} =
             Signing.verify_commit(deployment_commit, ctx.cell_ctx.public_key)

    durable_identity = ctx.durable_identity

    assert {:ok, ^durable_identity, cell_fingerprint} =
             Signing.parse_signer_id(cell_commit.signer_id)

    assert {:ok, ^durable_identity, deployment_fingerprint} =
             Signing.parse_signer_id(deployment_commit.signer_id)

    refute cell_fingerprint == deployment_fingerprint
  end

  defp mint_cell!(ctx, opts \\ []) do
    verbs = Keyword.get(opts, :verbs, [:read, :write, :delegate])

    claim = %{
      verbs: verbs,
      scope: {:subtree, ctx.subtree_root},
      caveats: %{not_before: ctx.parent_not_before, not_after: ctx.parent_not_after}
    }

    {:ok, cell} =
      Capability.issue(ctx.root_ctx, keyed(ctx.cell_ctx), claim, nil, store: ctx.store)

    cell
  end

  defp deployment_claim(ctx, overrides \\ []) do
    %{
      verbs: [:write],
      scope: {:subtree, ctx.subtree_root},
      caveats: %{
        not_before: Keyword.get(overrides, :not_before, ctx.child_not_before),
        not_after: Keyword.get(overrides, :not_after, ctx.child_not_after)
      }
    }
  end

  defp store_capabilities(store, capabilities) do
    Enum.each(capabilities, fn capability ->
      :ok = CommitStoreClient.store_capability(store, capability)
    end)

    :ok
  end

  defp capability_present?(store, id),
    do: match?({:ok, %Capability{}}, CommitStoreClient.get_capability(store, id))

  defp same_root?(%{scope: {:subtree, root}}, %{scope: {:subtree, root}}), do: true
  defp same_root?(_child, _parent), do: false

  defp verbs_subset?(child, parent),
    do: MapSet.subset?(MapSet.new(child.verbs), MapSet.new(parent.verbs))

  defp window_within?(child, parent) do
    DateTime.compare(child.caveats.not_before, parent.caveats.not_before) in [:eq, :gt] and
      DateTime.compare(child.caveats.not_after, parent.caveats.not_after) in [:eq, :lt]
  end

  defp anchors(ctx), do: MapSet.new([ctx.root_ctx.public_key])

  defp keyed(ctx), do: {ctx.identity_uuid, ctx.public_key}

  defp signing_context(identity_uuid) do
    {public_key, private_key} = Signing.generate_keypair()

    %SigningContext{
      identity_uuid: identity_uuid,
      public_key: public_key,
      private_key: private_key
    }
  end

  defp trust_config(root_ctx) do
    %{
      accept_unsigned: false,
      trusted_identities: %{
        root_ctx.identity_uuid => Signing.encode_key(root_ctx.public_key)
      }
    }
  end
end

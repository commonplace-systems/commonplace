defmodule Commonplace.Identity.ClassRatificationTest do
  @moduledoc """
  I3's fixture is modelled on I2's `SpawnCeremonyTest`, which was modelled on
  I1's `RootScopeGateTest`, which was modelled on `Trust.SubtreeCarveTest`.

  It preserves I2's enforcing isolated store, explicit fixture signing context,
  and child-workspace key custody. The constructed red-first arm intentionally
  passes a pinned ref through `DocRef.uuid/1`, then reads latest, to exhibit
  the amendment leak before the production pinned-read path is exercised.
  """

  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Document.{ContentType, DocRef}
  alias Commonplace.Identity.{ClassRatification, SpawnCeremony}
  alias Commonplace.Store.{Commit, CommitStoreClient, SecretStore}
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Commonplace.Trust
  alias Commonplace.Trust.{Capability, VerifyChain}
  alias Commonplace.WriterHand
  alias Yelixer.{Doc, Encoding}

  setup do
    data_dir = Path.join(System.tmp_dir!(), "cp_i3_class_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(data_dir)
    n = :rand.uniform(1_000_000_000)
    store = :"i3_class_store_#{n}"
    child_secrets = :"i3_child_secrets_#{n}"
    steward = signing_context("fixture-steward")

    File.write!(
      Path.join(data_dir, "trust.json"),
      Jason.encode!(%{
        "accept_unsigned" => false,
        "trusted_identities" => %{
          steward.identity_uuid => Signing.encode_key(steward.public_key)
        }
      })
    )

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: data_dir,
       name: :"i3_class_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"i3_class_tss_#{n}",
       pending_imports_name: :"i3_class_pi_#{n}",
       local_write_gate: :enforce}
    )

    start_supervised!(%{
      id: child_secrets,
      start:
        {SecretStore, :start_link,
         [
           [
             data_dir: Path.join(data_dir, "child-workspace"),
             name: child_secrets,
             auto_compact: false
           ]
         ]}
    })

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema(client_id: WriterHand.for_doc(root_uuid))

    assert %Commit{} =
             CommitStoreClient.create_commit(
               store,
               root_uuid,
               Encoding.encode_update(root_doc),
               nil,
               %{kind: :regular},
               signing_context: steward
             )

    allowed_ref = create_record(store, steward, "seed", %{"revision" => 0})

    {:ok, parent_capability} =
      Capability.issue(
        steward,
        {steward.identity_uuid, steward.public_key},
        %{
          verbs: [:read, :write, :delegate],
          scope: {:docs, [allowed_ref.uuid]},
          caveats: %{not_before: nil, not_after: nil}
        }
      )

    :ok = CommitStoreClient.store_capability(store, parent_capability)

    {:ok, class_writer} =
      start_supervised(
        {ClassRatification,
         name: "platform-watch",
         class: class_contract(allowed_ref.uuid, "durable"),
         store: store,
         signing_context: steward}
      )

    class_ref = class_writer |> ClassRatification.snapshot() |> Map.fetch!(:class_ref)

    {:ok, ceremony} =
      start_supervised(
        {SpawnCeremony,
         root_uuid: root_uuid,
         store: store,
         signing_context: steward,
         issuer_signing_context: steward}
      )

    %{
      allowed_ref: allowed_ref,
      ceremony: ceremony,
      child_secrets: child_secrets,
      class_ref: class_ref,
      class_writer: class_writer,
      parent_capability: parent_capability,
      steward: steward,
      store: store
    }
  end

  test "an in-class spawn completes after the steward process is observed down", ctx do
    request = request("no-steward-watch", ctx, ctx.class_ref, "durable")
    monitor = Process.monitor(ctx.class_writer)
    :ok = GenServer.stop(ctx.class_writer)
    assert_receive {:DOWN, ^monitor, :process, class_writer, :normal}
    assert class_writer == ctx.class_writer

    spawn_outcome =
      SpawnCeremony.spawn_child(ctx.ceremony, request, child_secret_store: ctx.child_secrets)

    assert {:ok, active} = spawn_outcome
    assert active.status == :active
    assert {:ok, class} = ClassRatification.class_for_identity(active.child_uuid, ctx.store)
    assert_write_gate_arms(active, ctx.allowed_ref.uuid, ctx.steward, ctx.store)

    observed = %{
      class_sla: class["sla"],
      spawn_status: active.status,
      steward_down_reason: :normal
    }

    assert observed == %{
             class_sla: "durable",
             spawn_status: :active,
             steward_down_reason: :normal
           }

    IO.puts("IN_CLASS_NO_STEWARD_OUTCOME=#{inspect(observed)}")
  end

  test "an out-of-class spawn refuses and names the mission field", ctx do
    in_class_request = request("in-class-control", ctx, ctx.class_ref, "durable")

    out_of_class_request = %{
      request("out-of-class", ctx, ctx.class_ref, "durable")
      | mission: "rewrite production"
    }

    in_class_outcome =
      SpawnCeremony.spawn_child(ctx.ceremony, in_class_request,
        child_secret_store: ctx.child_secrets
      )

    out_of_class_outcome =
      SpawnCeremony.spawn_child(ctx.ceremony, out_of_class_request,
        child_secret_store: ctx.child_secrets
      )

    assert {:ok, %{status: :active}} = in_class_outcome
    assert out_of_class_outcome == {:error, {:spawn_outside_class, :mission}}
    refute in_class_outcome == out_of_class_outcome

    IO.puts("IN_CLASS_CONTROL_OUTCOME=#{inspect(in_class_outcome)}")
    IO.puts("OUT_OF_CLASS_OUTCOME=#{inspect(out_of_class_outcome)}")
    IO.puts("CLASS_BOUNDARY_OUTCOMES_DIFFER=#{in_class_outcome != out_of_class_outcome}")
  end

  test "amendment leaks through the constructed naive resolve but not through the pinned child",
       ctx do
    existing_request = request("existing-child", ctx, ctx.class_ref, "durable")

    assert {:ok, existing_child} =
             SpawnCeremony.spawn_child(ctx.ceremony, existing_request,
               child_secret_store: ctx.child_secrets
             )

    assert {:ok, amendment} =
             ClassRatification.amend(
               ctx.class_writer,
               class_contract(ctx.allowed_ref.uuid, "ephemeral")
             )

    amended_ref = amendment.class_ref
    new_request = request("new-child", ctx, amended_ref, "ephemeral")

    assert {:ok, new_child} =
             SpawnCeremony.spawn_child(ctx.ceremony, new_request,
               child_secret_store: ctx.child_secrets
             )

    naive_existing_outcome = naive_latest_class_for_identity(existing_child.child_uuid, ctx.store)
    naive_new_outcome = naive_latest_class_for_identity(new_child.child_uuid, ctx.store)

    assert {:ok, %{"sla" => "ephemeral"}} = naive_existing_outcome
    assert naive_existing_outcome == naive_new_outcome

    pinned_existing_outcome =
      ClassRatification.class_for_identity(existing_child.child_uuid, ctx.store)

    pinned_new_outcome = ClassRatification.class_for_identity(new_child.child_uuid, ctx.store)

    assert {:ok, %{"sla" => "durable"}} = pinned_existing_outcome
    assert {:ok, %{"sla" => "ephemeral"}} = pinned_new_outcome
    refute pinned_existing_outcome == pinned_new_outcome

    IO.puts("NAIVE_EXISTING_AFTER_AMEND=#{inspect(naive_existing_outcome)}")
    IO.puts("NAIVE_NEW_AFTER_AMEND=#{inspect(naive_new_outcome)}")
    IO.puts("NAIVE_AMENDMENT_LEAKED=#{naive_existing_outcome == naive_new_outcome}")
    IO.puts("PINNED_EXISTING_AFTER_AMEND=#{inspect(pinned_existing_outcome)}")
    IO.puts("PINNED_NEW_AFTER_AMEND=#{inspect(pinned_new_outcome)}")
    IO.puts("PINNED_OUTCOMES_DIFFER=#{pinned_existing_outcome != pinned_new_outcome}")
  end

  defp request(name, ctx, class_ref, sla) do
    %{
      auditor_role: "fixture-auditor",
      budget: "fixture-budget",
      child_workspace_id: "fixture-child-workspace",
      class_ref: DocRef.to_string(class_ref),
      context_seed: [DocRef.to_string(ctx.allowed_ref)],
      delegation_depth: 0,
      escalation_parent: "fixture-steward",
      grant: %{
        verbs: [:write],
        scope: {:docs, [ctx.allowed_ref.uuid]},
        caveats: %{not_before: nil, not_after: nil}
      },
      initial_cell: "fixture-cell",
      lifetime: "fixture-lifetime",
      mission: "observe the fixture",
      name: name,
      parent_capability: ctx.parent_capability,
      parent_delegation_depth: 1,
      sla: sla
    }
  end

  defp class_contract(allowed_uuid, sla) do
    %{
      auditor_role: "fixture-auditor",
      escalation_parent: "fixture-steward",
      mission_template: "observe the fixture",
      scope_envelope: [allowed_uuid],
      sla: sla
    }
  end

  defp naive_latest_class_for_identity(identity_uuid, store) do
    with {:ok, root} <- Commonplace.Identity.Root.read(identity_uuid, store),
         {:ok, ref} <- DocRef.parse(get_in(root, ["genesis", "class_ref"])),
         {:ok, bare_uuid} <- DocRef.uuid(ref),
         {:ok, doc} <- DocBuilder.reconstruct_doc(store, bare_uuid),
         body when is_binary(body) <- ContentType.get_content(doc),
         {:ok, class} <- Jason.decode(body) do
      {:ok, class}
    end
  end

  defp signing_context(identity_uuid) do
    {public_key, private_key} = Signing.generate_keypair()

    %SigningContext{
      identity_uuid: identity_uuid,
      public_key: public_key,
      private_key: private_key
    }
  end

  defp assert_write_gate_arms(active, target_uuid, anchor, store) do
    [cert_cid] = Enum.map(active.capability_proofs, &decode_cid/1)

    assert {:ok, cert} = CommitStoreClient.get_capability(store, cert_cid)
    child_uuid = active.child_uuid
    assert {^child_uuid, child_public_key} = cert.audience

    assert {:ok, %{verbs: verbs, scope: {:docs, scope}}} =
             VerifyChain.verify_chain(cert_cid, MapSet.new([anchor.public_key]), store)

    assert :write in verbs
    assert target_uuid in scope
    assert {:ok, _target_doc} = DocBuilder.reconstruct_doc(store, target_uuid)

    cfg = %{
      accept_unsigned: false,
      trusted_identities: %{
        anchor.identity_uuid => Signing.encode_key(anchor.public_key)
      }
    }

    assert Trust.writer_authorized?(
             child_uuid,
             child_public_key,
             [cert_cid],
             target_uuid,
             cfg,
             store
           )

    ungranted = signing_context("ungranted-class-principal")
    assert ungranted.identity_uuid != child_uuid
    assert ungranted.public_key != child_public_key
    assert {:ok, ^cert} = CommitStoreClient.get_capability(store, cert_cid)

    assert {:ok, %{verbs: refusal_verbs, scope: {:docs, refusal_scope}}} =
             VerifyChain.verify_chain(cert_cid, MapSet.new([anchor.public_key]), store)

    assert :write in refusal_verbs
    assert target_uuid in refusal_scope
    assert {:ok, _target_doc} = DocBuilder.reconstruct_doc(store, target_uuid)

    refute Trust.writer_authorized?(
             ungranted.identity_uuid,
             ungranted.public_key,
             [cert_cid],
             target_uuid,
             cfg,
             store
           )
  end

  defp create_record(store, signer, name, contents) do
    uuid = UUID.uuid4()
    body = contents |> Map.put("zone", uuid) |> Jason.encode!()
    doc = Doc.new(client_id: WriterHand.for_doc(uuid))
    doc = ContentType.create(doc, :text, name)
    doc = ContentType.insert_text(doc, 0, body)

    assert %Commit{} =
             CommitStoreClient.create_commit(
               store,
               uuid,
               Encoding.encode_update(doc),
               nil,
               %{kind: :regular},
               signing_context: signer
             )

    DocRef.new(uuid, path: "fixture/#{name}")
  end

  defp decode_cid(hex) do
    {:ok, cid} = Base.decode16(hex, case: :mixed)
    cid
  end
end

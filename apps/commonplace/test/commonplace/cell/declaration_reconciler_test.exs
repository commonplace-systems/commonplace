defmodule Commonplace.Cell.DeclarationReconcilerTest do
  use ExUnit.Case, async: true

  alias Commonplace.Cell.{Declaration, DeclarationProducer, DeclarationReconciler}
  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Document.{ContentType, DocRef}
  alias Commonplace.Identity.{ClassRatification, SpawnCeremony}
  alias Commonplace.Store.{Commit, CommitStoreClient}
  alias Commonplace.Tree.Schema
  alias Commonplace.Trust.Capability
  alias Commonplace.WriterHand
  alias Yelixer.{Doc, Encoding}

  setup do
    {public_key, _private_key} = Signing.generate_keypair()
    encoded_public_key = Signing.encode_key(public_key)

    declaration = %{
      "child_uuid" => UUID.uuid4(),
      "name" => "platform-watch",
      "public_key" => encoded_public_key
    }

    path =
      Path.join(
        System.tmp_dir!(),
        "cell-declaration-reconciler-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    %{declaration: declaration, path: path}
  end

  test "a healthy bounded projection reports no divergence", ctx do
    write_declaration!(ctx.path, ctx.declaration)

    receipt =
      ctx.declaration
      |> Map.put("request_digest", "receipt-only-digest")
      |> Map.put("status", "active")

    ceremony = start_receipt_server(%{ctx.declaration["name"] => {:ok, receipt}})

    assert {:ok, []} =
             DeclarationReconciler.reconcile(ceremony, ctx.declaration["name"], ctx.path)
  end

  test "a field disagreement goes red with the divergence named", ctx do
    write_declaration!(ctx.path, ctx.declaration)

    receipt =
      ctx.declaration
      |> Map.put("child_uuid", UUID.uuid4())
      |> Map.put("request_digest", "receipt-only-digest")
      |> Map.put("status", "active")

    ceremony = start_receipt_server(%{ctx.declaration["name"] => {:ok, receipt}})

    assert {:ok,
            [
              %{
                kind: :child_uuid_mismatch,
                declaration: declaration_uuid,
                receipt: receipt_uuid
              }
            ]} = DeclarationReconciler.reconcile(ceremony, ctx.declaration["name"], ctx.path)

    assert declaration_uuid == ctx.declaration["child_uuid"]
    assert receipt_uuid == receipt["child_uuid"]
  end

  test "a never-spawned cell is distinguished from a healthy one", ctx do
    ceremony = start_receipt_server(%{})

    assert {:ok, :nothing_to_compare} =
             DeclarationReconciler.reconcile(ceremony, ctx.declaration["name"], ctx.path)

    refute {:ok, :nothing_to_compare} == {:ok, []}
  end

  test "both missing-arm directions are named", ctx do
    receipt =
      ctx.declaration
      |> Map.put("request_digest", "receipt-only-digest")
      |> Map.put("status", "active")

    receipt_ceremony =
      start_receipt_server(%{ctx.declaration["name"] => {:ok, receipt}})

    assert {:ok, [%{kind: :declaration_missing}]} =
             DeclarationReconciler.reconcile(
               receipt_ceremony,
               ctx.declaration["name"],
               ctx.path
             )

    write_declaration!(ctx.path, ctx.declaration)
    missing_receipt_ceremony = start_receipt_server(%{})

    assert {:ok, [%{kind: :receipt_missing}]} =
             DeclarationReconciler.reconcile(
               missing_receipt_ceremony,
               ctx.declaration["name"],
               ctx.path
             )
  end

  test "an invalid declaration is a named divergence", ctx do
    File.write!(ctx.path, "not-json")

    receipt =
      ctx.declaration
      |> Map.put("request_digest", "receipt-only-digest")
      |> Map.put("status", "active")

    ceremony = start_receipt_server(%{ctx.declaration["name"] => {:ok, receipt}})

    assert {:ok,
            [
              %{
                kind: :declaration_invalid,
                reason: {:invalid_declaration, "declaration", "must be valid JSON"}
              }
            ]} = DeclarationReconciler.reconcile(ceremony, ctx.declaration["name"], ctx.path)
  end

  test "a real SpawnCeremony receipt reconciles clean against its own declaration" do
    data_dir =
      Path.join(System.tmp_dir!(), "cp_reconciler_real_#{:rand.uniform(1_000_000_000)}")

    File.mkdir_p!(data_dir)
    n = :rand.uniform(1_000_000_000)
    store = :"reconciler_real_store_#{n}"
    child_secrets = :"reconciler_real_child_secrets_#{n}"
    parent = signing_context("fixture-anchor-reconciler")

    File.write!(
      Path.join(data_dir, "trust.json"),
      Jason.encode!(%{
        "accept_unsigned" => false,
        "trusted_identities" => %{
          parent.identity_uuid => Signing.encode_key(parent.public_key)
        }
      })
    )

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: data_dir,
       name: :"reconciler_real_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"reconciler_real_tss_#{n}",
       pending_imports_name: :"reconciler_real_pi_#{n}",
       local_write_gate: :enforce}
    )

    start_supervised!(%{
      id: child_secrets,
      start:
        {Commonplace.Store.SecretStore, :start_link,
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
               signing_context: parent
             )

    allowed_ref = create_real_record(store, parent, "seed", %{"revision" => 0})

    {:ok, parent_capability} =
      Capability.issue(
        parent,
        {parent.identity_uuid, parent.public_key},
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
         name: "reconciler-real-watch",
         class: %{
           auditor_role: "fixture-auditor",
           escalation_parent: parent.identity_uuid,
           mission_template: "observe the fixture",
           scope_envelope: [allowed_ref.uuid],
           sla: "durable"
         },
         store: store,
         signing_context: parent}
      )

    class_ref = class_writer |> ClassRatification.snapshot() |> Map.fetch!(:class_ref)

    {:ok, ceremony} =
      start_supervised(
        {SpawnCeremony,
         root_uuid: root_uuid,
         store: store,
         signing_context: parent,
         issuer_signing_context: parent}
      )

    request = %{
      auditor_role: "fixture-auditor",
      budget: "fixture-budget",
      child_workspace_id: "fixture-child-workspace",
      class_ref: DocRef.to_string(class_ref),
      context_seed: [DocRef.to_string(allowed_ref)],
      delegation_depth: 0,
      escalation_parent: parent.identity_uuid,
      grant: %{
        verbs: [:write],
        scope: {:docs, [allowed_ref.uuid]},
        caveats: %{not_before: nil, not_after: nil}
      },
      initial_cell: "fixture-cell",
      lifetime: "fixture-lifetime",
      mission: "observe the fixture",
      name: "reconciler-real-watch",
      parent_capability: parent_capability,
      parent_delegation_depth: 1,
      sla: "durable"
    }

    assert {:ok, %{status: :active}} =
             SpawnCeremony.spawn_child(ceremony, request, child_secret_store: child_secrets)

    declaration_path = Path.join(data_dir, "reconciler-real-watch.json")

    assert {:ok, _declaration} =
             DeclarationProducer.write(ceremony, request.name, declaration_path)

    assert {:ok, []} =
             DeclarationReconciler.reconcile(ceremony, request.name, declaration_path)
  end

  test "the divergence vocabulary is closed and enumerated" do
    assert DeclarationReconciler.divergence_kinds() == [
             :declaration_missing,
             :receipt_missing,
             :declaration_invalid,
             :child_uuid_mismatch,
             :name_mismatch,
             :public_key_mismatch
           ]
  end

  defp write_declaration!(path, declaration) do
    assert {:ok, document} = Declaration.encode(declaration)
    File.write!(path, document)
  end

  defp start_receipt_server(receipts) do
    start_supervised!({Task, fn -> receipt_loop(receipts) end},
      id: {__MODULE__, System.unique_integer([:positive])}
    )
  end

  defp receipt_loop(receipts) do
    receive do
      {:"$gen_call", from, {:read_public_receipt, name}} ->
        GenServer.reply(from, Map.get(receipts, name, {:error, :receipt_not_found}))
        receipt_loop(receipts)
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

  defp create_real_record(store, signer, name, contents) do
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
end

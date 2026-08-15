defmodule Commonplace.Identity.SpawnCeremonyTest do
  @moduledoc """
  I2's ceremony fixture is modelled on I1's
  `Commonplace.Identity.RootScopeGateTest`, which was itself modelled on
  `Commonplace.Trust.SubtreeCarveTest`. It preserves I1's isolated enforcing
  store and explicit fixture-anchor signing-context pattern, then adds two
  distinct SecretStores so key custody is measured by workspace.
  """

  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{AgentKeys, Signing, SigningContext}
  alias Commonplace.Document.{ContentType, DocRef}
  alias Commonplace.Identity.{Root, SpawnCeremony}
  alias Commonplace.Store.{Commit, CommitStoreClient, SecretStore}
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Commonplace.Trust.Capability
  alias Commonplace.WriterHand
  alias Yelixer.{Doc, Encoding}

  setup do
    data_dir = Path.join(System.tmp_dir!(), "cp_i2_spawn_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(data_dir)
    n = :rand.uniform(1_000_000_000)
    store = :"i2_spawn_store_#{n}"
    parent_secrets = :"i2_parent_secrets_#{n}"
    child_secrets = :"i2_child_secrets_#{n}"
    parent = signing_context("fixture-anchor")

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
       name: :"i2_spawn_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"i2_spawn_tss_#{n}",
       pending_imports_name: :"i2_spawn_pi_#{n}",
       local_write_gate: :enforce}
    )

    start_supervised!(%{
      id: parent_secrets,
      start:
        {SecretStore, :start_link,
         [
           [
             data_dir: Path.join(data_dir, "parent-workspace"),
             name: parent_secrets,
             auto_compact: false
           ]
         ]}
    })

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

    {:ok, _parent_workspace_key} = AgentKeys.ensure(parent.identity_uuid, parent_secrets)

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

    allowed_ref = create_record(store, parent, "seed", %{"revision" => 0})
    extra_uuid = UUID.uuid4()

    {:ok, parent_capability} =
      Capability.issue(
        parent,
        {parent.identity_uuid, parent.public_key},
        %{
          verbs: [:read, :write],
          scope: {:docs, [allowed_ref.uuid]},
          caveats: %{not_before: nil, not_after: nil}
        }
      )

    :ok = CommitStoreClient.store_capability(store, parent_capability)

    {:ok, ceremony} =
      start_supervised(
        {SpawnCeremony,
         root_uuid: root_uuid,
         store: store,
         signing_context: parent,
         issuer_signing_context: parent}
      )

    request = request("platform-watch-2", allowed_ref, parent_capability)

    %{
      allowed_ref: allowed_ref,
      ceremony: ceremony,
      child_secrets: child_secrets,
      extra_uuid: extra_uuid,
      parent: parent,
      parent_capability: parent_capability,
      parent_secrets: parent_secrets,
      request: request,
      root_uuid: root_uuid,
      store: store
    }
  end

  test "identical retry resolves one child and a changed request names conflict", ctx do
    assert {:ok, first} =
             SpawnCeremony.spawn_child(ctx.ceremony, ctx.request,
               child_secret_store: ctx.child_secrets
             )

    assert {:ok, retry} =
             SpawnCeremony.spawn_child(ctx.ceremony, ctx.request,
               child_secret_store: ctx.child_secrets
             )

    restarted_ceremony =
      start_supervised!(%{
        id: :"i2_restarted_ceremony_#{:rand.uniform(1_000_000_000)}",
        start:
          {SpawnCeremony, :start_link,
           [
             [
               root_uuid: ctx.root_uuid,
               store: ctx.store,
               signing_context: ctx.parent,
               issuer_signing_context: ctx.parent
             ]
           ]}
      })

    assert {:ok, after_restart} =
             SpawnCeremony.spawn_child(restarted_ceremony, ctx.request,
               child_secret_store: ctx.child_secrets
             )

    assert first.child_uuid == retry.child_uuid
    assert first.child_uuid == after_restart.child_uuid
    assert first.status == :active
    assert :ok = SpawnCeremony.deployment_permitted?(ctx.ceremony, ctx.request)

    conflict_request = %{ctx.request | mission: "a materially different mission"}

    assert {:error, {:spawn_request_conflict, conflict}} =
             SpawnCeremony.spawn_child(ctx.ceremony, conflict_request,
               child_secret_store: ctx.child_secrets
             )

    assert conflict.name == ctx.request.name
    refute conflict.existing_digest == conflict.requested_digest

    assert {:ok, root} = Root.read(first.child_uuid, ctx.store)
    assert root["genesis"]["activation"] == first.activation

    assert {:ok, birth_commit} =
             root["genesis"]["birth_commit"]
             |> decode_cid()
             |> then(&CommitStoreClient.get_commit(ctx.store, &1))

    assert String.starts_with?(birth_commit.signer_id, ctx.parent.identity_uuid <> "@")

    assert {:ok, activation_commit} =
             first.activation
             |> decode_cid()
             |> then(&CommitStoreClient.get_commit(ctx.store, &1))

    assert {:ok, activation_doc} =
             DocBuilder.reconstruct_doc(ctx.store, activation_commit.doc_uuid)

    assert {:ok, activation} =
             activation_doc
             |> ContentType.get_content()
             |> Jason.decode()

    assert activation["child_uuid"] == first.child_uuid
    assert {:ok, child_public_key} = Signing.decode_key(activation["child_public_key"])
    assert {:ok, child_signature} = Base.decode64(activation["child_signature"])

    activation_payload =
      Map.drop(activation, ["child_public_key", "child_signature"])

    activation_digest =
      activation_payload
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))

    assert :crypto.verify(
             :eddsa,
             :none,
             activation_digest,
             child_signature,
             [child_public_key, :ed25519]
           )

    assert {:ok, _cert} =
             first.capability_proofs
             |> hd()
             |> decode_cid()
             |> then(&CommitStoreClient.get_capability(ctx.store, &1))

    IO.puts("IDEMPOTENT_FIRST_ID=#{first.child_uuid}")
    IO.puts("IDEMPOTENT_RETRY_ID=#{retry.child_uuid}")
    IO.puts("IDEMPOTENT_AFTER_RESTART_ID=#{after_restart.child_uuid}")
    IO.puts("IDEMPOTENT_IDS_EQUAL=#{first.child_uuid == retry.child_uuid}")
    IO.puts("CONFLICT_OUTCOME=#{inspect({:error, {:spawn_request_conflict, conflict}})}")
  end

  test "partial birth stays provisioning and SpawnCeremony.authorize_action/2 refuses its write",
       ctx do
    request = %{ctx.request | name: "partial-watch"}

    assert {:ok, partial} =
             SpawnCeremony.spawn_child(ctx.ceremony, request,
               child_secret_store: ctx.child_secrets,
               halt_after: :birth
             )

    assert partial.status == :provisioning

    assert {:error, {:action_refused, :identity_provisioning}} =
             SpawnCeremony.authorize_action(ctx.ceremony, request)

    before = reread_record(ctx.allowed_ref, ctx.store)

    refusal =
      SpawnCeremony.write_record(
        ctx.ceremony,
        request,
        ctx.allowed_ref,
        %{"zone" => ctx.allowed_ref.uuid, "revision" => 1},
        store: ctx.store
      )

    assert refusal == {:error, {:action_refused, :identity_provisioning}}
    assert reread_record(ctx.allowed_ref, ctx.store) == before

    assert {:ok, active} =
             SpawnCeremony.spawn_child(ctx.ceremony, request,
               child_secret_store: ctx.child_secrets
             )

    assert active.child_uuid == partial.child_uuid
    assert :ok = SpawnCeremony.authorize_action(ctx.ceremony, request)
    refute refusal == :ok

    IO.puts("PARTIAL_ID=#{partial.child_uuid} status=#{partial.status}")
    IO.puts("PARTIAL_WRITE_OUTCOME=#{inspect(refusal)}")

    IO.puts(
      "ACTIVE_ACTION_CONTROL=#{inspect(SpawnCeremony.authorize_action(ctx.ceremony, request))}"
    )

    IO.puts("ACTION_OUTCOMES_DIFFER=#{refusal != :ok}")
  end

  test "an over-broad requested scope refuses at certificate mint", ctx do
    broad_request =
      ctx.request
      |> Map.put(:name, "over-broad-watch")
      |> put_in([:grant, :scope], {:docs, [ctx.allowed_ref.uuid, ctx.extra_uuid]})

    narrow_outcome =
      SpawnCeremony.spawn_child(ctx.ceremony, %{ctx.request | name: "narrow-control"},
        child_secret_store: ctx.child_secrets
      )

    broad_outcome =
      SpawnCeremony.spawn_child(ctx.ceremony, broad_request,
        child_secret_store: ctx.child_secrets
      )

    assert {:ok, %{status: :active}} = narrow_outcome
    assert broad_outcome == {:error, {:grant_outside_parent_holdings, :scope}}
    refute narrow_outcome == broad_outcome

    IO.puts("NARROW_MINT_CONTROL=#{inspect(narrow_outcome)}")
    IO.puts("OVER_BROAD_MINT_OUTCOME=#{inspect(broad_outcome)}")
    IO.puts("MINT_OUTCOMES_DIFFER=#{narrow_outcome != broad_outcome}")
  end

  test "the identical private-key search finds child custody and no parent copy", ctx do
    assert {:ok, active} =
             SpawnCeremony.spawn_child(ctx.ceremony, %{ctx.request | name: "custody-watch"},
               child_secret_store: ctx.child_secrets
             )

    child_matches = private_key_search(ctx.child_secrets, active.child_uuid)
    parent_matches = private_key_search(ctx.parent_secrets, active.child_uuid)

    assert child_matches == ["signing_key:#{active.child_uuid}"]
    assert length(child_matches) == 1
    assert parent_matches == []
    assert length(parent_matches) == 0
    refute child_matches == parent_matches

    IO.puts("KEY_SEARCH_CHILD_CONTROL=#{inspect(child_matches)} count=#{length(child_matches)}")
    IO.puts("KEY_SEARCH_PARENT=#{inspect(parent_matches)} count=#{length(parent_matches)}")
    IO.puts("KEY_SEARCH_OUTCOMES_DIFFER=#{child_matches != parent_matches}")
  end

  defp request(name, allowed_ref, parent_capability) do
    %{
      budget: "fixture-budget",
      child_workspace_id: "fixture-child-workspace",
      class_ref: "classes/platform-watch:00000000-0000-0000-0000-000000000001@fixture-class-cid",
      context_seed: [DocRef.to_string(allowed_ref)],
      delegation_depth: 0,
      grant: %{
        verbs: [:write],
        scope: {:docs, [allowed_ref.uuid]},
        caveats: %{not_before: nil, not_after: nil}
      },
      initial_cell: "fixture-cell",
      lifetime: "fixture-lifetime",
      mission: "observe the fixture",
      name: name,
      parent_capability: parent_capability,
      parent_delegation_depth: 1
    }
  end

  defp signing_context(identity_uuid) do
    {public_key, private_key} = Signing.generate_keypair()

    %SigningContext{
      identity_uuid: identity_uuid,
      public_key: public_key,
      private_key: private_key
    }
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

  defp reread_record(ref, store) do
    assert {:ok, doc} = DocBuilder.reconstruct_doc(store, ref.uuid)
    assert {:ok, body} = doc |> ContentType.get_content() |> Jason.decode()
    body
  end

  defp private_key_search(secret_store, child_uuid) do
    wanted = "signing_key:#{child_uuid}"
    secret_store |> SecretStore.list() |> Enum.filter(&(&1 == wanted))
  end

  defp decode_cid(hex) do
    {:ok, cid} = Base.decode16(hex, case: :mixed)
    cid
  end
end

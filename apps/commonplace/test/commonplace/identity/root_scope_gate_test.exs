defmodule Commonplace.Identity.RootScopeGateTest do
  @moduledoc """
  I1's two-arm fixture. It is modelled on
  `Commonplace.Trust.SubtreeCarveTest`'s real local-write-gate fixture, with
  two deliberate differences: node signing is replaced by injected fixture
  contexts, and the SAME child cert is attached to both arms.

  `charter` is synthetic-from-spec and exists only as the forbidden target;
  the landed identity root still contains exactly one governed DocRef,
  `records.understanding`.
  """

  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Document.{ContentType, DocRef}
  alias Commonplace.Identity.Root
  alias Commonplace.Store.{Commit, CommitStoreClient}
  alias Commonplace.Tree.Schema
  alias Commonplace.Trust.Capability
  alias Commonplace.WriterHand
  alias Yelixer.{Doc, Encoding}

  setup do
    data_dir = Path.join(System.tmp_dir!(), "cp_i1_identity_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(data_dir)
    n = :rand.uniform(1_000_000_000)
    store = :"i1_identity_store_#{n}"

    issuer = signing_context("fixture-anchor")
    child = signing_context("fixture-child")

    File.write!(
      Path.join(data_dir, "trust.json"),
      Jason.encode!(%{
        "accept_unsigned" => false,
        "trusted_identities" => %{
          issuer.identity_uuid => Signing.encode_key(issuer.public_key)
        }
      })
    )

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: data_dir,
       name: :"i1_identity_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"i1_identity_tss_#{n}",
       pending_imports_name: :"i1_identity_pi_#{n}",
       local_write_gate: :enforce}
    )

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema(client_id: WriterHand.for_doc(root_uuid))

    assert %Commit{} =
             CommitStoreClient.create_commit(
               store,
               root_uuid,
               Encoding.encode_update(root_doc),
               nil,
               %{kind: :regular},
               signing_context: issuer
             )

    %{data_dir: data_dir, store: store, issuer: issuer, child: child, root_uuid: root_uuid}
  end

  test "same understanding-scoped cert lands understanding and refuses charter", ctx do
    genesis = %{
      "created_by" => ctx.issuer.identity_uuid,
      "birth_commit" => "fixture-birth-cid",
      "activation" => "fixture-activation-cid",
      "class_ref" =>
        "classes/platform-watch:00000000-0000-0000-0000-000000000001@fixture-class-cid"
    }

    {:ok, server} =
      start_supervised(
        {Root,
         root_uuid: ctx.root_uuid,
         name: "platform-watch-1",
         genesis: genesis,
         understanding: %{"revision" => 0, "summary" => "empty"},
         store: ctx.store,
         signing_context: ctx.issuer}
      )

    snapshot = Root.snapshot(server)
    understanding_ref = snapshot.records["understanding"]

    assert {:ok, landed_root} = Root.read(snapshot.root_uuid, ctx.store)
    assert landed_root["genesis"] == genesis
    assert Map.keys(landed_root["records"]) == ["understanding"]
    assert landed_root["records"]["understanding"] == DocRef.to_string(understanding_ref)

    {:ok, cert} =
      Capability.issue(
        ctx.issuer,
        {ctx.child.identity_uuid, ctx.child.public_key},
        %{verbs: [:write], scope: {:subtree, understanding_ref.uuid}, caveats: %{}},
        nil,
        store: ctx.store
      )

    :ok = CommitStoreClient.store_capability(ctx.store, cert)

    write_outcome =
      Root.write_record(
        understanding_ref,
        %{"zone" => understanding_ref.uuid, "revision" => 1, "summary" => "re-read me"},
        ctx.store,
        signing_context: ctx.child,
        capability_proof: cert.id
      )

    assert {:ok,
            %{
              attempted_path: "__identities__/platform-watch-1.json/records.understanding",
              cert_cid: cert_cid,
              cert_scope: {:subtree, understanding_uuid},
              commit_id: commit_id
            }} = write_outcome

    assert cert_cid == Base.encode16(cert.id, case: :lower)
    assert understanding_uuid == understanding_ref.uuid
    assert is_binary(commit_id) and byte_size(commit_id) > 0
    assert {:ok, understanding_reread} = Root.read_record(understanding_ref, ctx.store)
    assert understanding_reread["revision"] == 1
    assert map_size(understanding_reread) > 0

    charter_ref = synthetic_charter_ref(ctx.store, ctx.issuer)

    refusal_outcome =
      Root.write_record(
        charter_ref,
        %{"zone" => charter_ref.uuid, "purpose" => "child rewrote its own charter"},
        ctx.store,
        signing_context: ctx.child,
        capability_proof: cert.id
      )

    expected_refusal =
      {:error,
       {:record_write_refused,
        %{
          attempted_path: charter_ref.path,
          cert_cid: cert_cid,
          cert_scope: {:subtree, understanding_ref.uuid},
          gate_error: {:trust_rejected, :capability_insufficient}
        }}}

    assert refusal_outcome == expected_refusal
    assert {:ok, charter_reread} = Root.read_record(charter_ref, ctx.store)
    assert charter_reread["purpose"] == "steward-owned"
    assert map_size(charter_reread) > 0
    refute write_outcome == refusal_outcome

    IO.puts("WRITE_ARM outcome=#{inspect(write_outcome)}")

    IO.puts(
      "WRITE_ARM re_read=#{inspect(understanding_reread)} count=#{map_size(understanding_reread)}"
    )

    IO.puts("REFUSAL_ARM outcome=#{inspect(refusal_outcome)}")
    IO.puts("REFUSAL_ARM re_read=#{inspect(charter_reread)} count=#{map_size(charter_reread)}")
    IO.puts("OUTCOMES_DIFFER=#{write_outcome != refusal_outcome}")
  end

  defp signing_context(identity_uuid) do
    {public_key, private_key} = Signing.generate_keypair()

    %SigningContext{
      identity_uuid: identity_uuid,
      public_key: public_key,
      private_key: private_key
    }
  end

  defp synthetic_charter_ref(store, issuer) do
    uuid = UUID.uuid4()
    path = "__identities__/platform-watch-1.json/records.charter"

    body = Jason.encode!(%{"zone" => uuid, "purpose" => "steward-owned"})
    doc = Doc.new(client_id: WriterHand.for_doc(uuid))
    doc = ContentType.create(doc, :text, "charter")
    doc = ContentType.insert_text(doc, 0, body)

    assert %Commit{} =
             CommitStoreClient.create_commit(
               store,
               uuid,
               Encoding.encode_update(doc),
               nil,
               %{kind: :regular},
               signing_context: issuer
             )

    DocRef.new(uuid, path: path)
  end
end

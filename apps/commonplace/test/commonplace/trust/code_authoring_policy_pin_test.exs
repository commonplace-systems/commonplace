defmodule Commonplace.Trust.CodeAuthoringPolicyPinTest do
  @moduledoc """
  CX-b38c: policy pins for delegated code authoring. The mechanism is the
  existing capability path: an explicit `{:subtree, zone}[:write, :execute]`
  cert may author code inside its zone, while verb attenuation and subtree
  membership continue to bind it.

  Every chain is rooted in this test's fixture signing context. It deliberately
  does not depend on the sandbox-masked local node trust anchor.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.MUD.{Schemas, World}
  alias Commonplace.Store.{Commit, CommitStoreClient}
  alias Commonplace.Tree.DocBuilder
  alias Commonplace.Trust
  alias Commonplace.Trust.{Capability, VerifyChain}

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cp_code_authoring_policy_#{:rand.uniform(1_000_000_000)}"
      )

    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"code_authoring_policy_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"code_authoring_policy_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"code_authoring_policy_tss_#{n}",
       pending_imports_name: :"code_authoring_policy_pi_#{n}"}
    )

    old_trust = Application.get_env(:commonplace, :trust)
    old_gate = Application.get_env(:commonplace, :local_write_gate)

    {root_pub, root_priv} = Signing.generate_keypair()

    root_ctx = %SigningContext{
      identity_uuid: "fixture-root",
      private_key: root_priv,
      public_key: root_pub
    }

    cfg = %{
      accept_unsigned: false,
      trusted_identities: %{root_ctx.identity_uuid => Signing.encode_key(root_pub)}
    }

    Application.put_env(:commonplace, :trust, cfg)
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    on_exit(fn ->
      restore_env(:trust, old_trust)
      restore_env(:local_write_gate, old_gate)
      File.rm_rf!(dir)
    end)

    %{store: store, root_ctx: root_ctx, cfg: cfg}
  end

  defp restore_env(key, nil), do: Application.delete_env(:commonplace, key)
  defp restore_env(key, value), do: Application.put_env(:commonplace, key, value)

  defp fixture_identity(id) do
    {pub, priv} = Signing.generate_keypair()
    ctx = %SigningContext{identity_uuid: id, private_key: priv, public_key: pub}
    %{id: id, pub: pub, ctx: ctx}
  end

  defp zoned_code_doc(store, root_ctx, zone) do
    {:ok, uuid} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Schemas.Room{name: "Code", description: "fixture"}),
        store,
        signing_context: root_ctx
      )

    :ok =
      World.set_meta(
        uuid,
        Schemas.room_filename(),
        "zone",
        zone,
        store,
        signing_context: root_ctx
      )

    %Commit{} = write_code(store, uuid, "defmodule Fixture.Base do\nend\n", nil, root_ctx)
    uuid
  end

  defp write_code(store, uuid, code, proof_cid, ctx) do
    {:ok, before} = DocBuilder.reconstruct_doc(store, uuid)

    after_doc =
      case ContentType.get_content(before) do
        content when is_binary(content) ->
          ContentType.insert_text(before, String.length(content), code)

        _ ->
          before |> ContentType.create(:text, "code.ex") |> ContentType.insert_text(0, code)
      end

    metadata =
      if proof_cid do
        %{kind: :regular, capability_proof: proof_cid}
      else
        %{kind: :regular}
      end

    CommitStoreClient.create_chained_commit(
      store,
      uuid,
      Yelixer.Encoding.encode_update(after_doc),
      metadata,
      signing_context: ctx
    )
  end

  defp issue_and_store(store, issuer_ctx, audience, verbs, scope, opts \\ []) do
    claim = %{verbs: verbs, scope: scope, caveats: %{not_before: nil, not_after: nil}}

    issue_opts = Keyword.merge([store: store], opts)
    parent_cid = issue_opts |> Keyword.get(:parent) |> then(&if(&1, do: &1.id, else: nil))

    {:ok, cert} =
      Capability.issue(issuer_ctx, {audience.id, audience.pub}, claim, parent_cid, issue_opts)

    :ok = CommitStoreClient.store_capability(store, cert)
    cert
  end

  test "pin 1: w+x subtree cert lands a code-classified write inside its zone", c do
    zone = UUID.uuid4()
    uuid = zoned_code_doc(c.store, c.root_ctx, zone)
    author = fixture_identity("code-author")
    cert = issue_and_store(c.store, c.root_ctx, author, [:write, :execute], {:subtree, zone})

    assert %Commit{} = write_code(c.store, uuid, "# delegated edit\n", cert.id, author.ctx)
  end

  test "pin 2: write-only subtree cert refuses a code-classified write inside its zone", c do
    zone = UUID.uuid4()
    uuid = zoned_code_doc(c.store, c.root_ctx, zone)
    author = fixture_identity("write-only-author")
    cert = issue_and_store(c.store, c.root_ctx, author, [:write], {:subtree, zone})

    assert {:error, {:trust_rejected, :capability_insufficient}} =
             write_code(c.store, uuid, "# refused edit\n", cert.id, author.ctx)
  end

  test "pin 3: w+x subtree cert refuses a code write outside its zone", c do
    inside_zone = UUID.uuid4()
    outside_uuid = zoned_code_doc(c.store, c.root_ctx, UUID.uuid4())
    author = fixture_identity("scoped-author")

    cert =
      issue_and_store(
        c.store,
        c.root_ctx,
        author,
        [:write, :execute],
        {:subtree, inside_zone}
      )

    assert {:error, {:trust_rejected, :capability_insufficient}} =
             write_code(c.store, outside_uuid, "# out of scope\n", cert.id, author.ctx)
  end

  test "pin 4: a w-only child attenuated from w+x refuses code authoring", c do
    zone = UUID.uuid4()
    uuid = zoned_code_doc(c.store, c.root_ctx, zone)
    parent_holder = fixture_identity("parent-author")
    child_holder = fixture_identity("non-code-child")

    # Subtree certs are currently leaf-only (ruling §2.4), so the existing
    # delegation chain is exercised at doc scope while the target stays zoned.
    parent =
      issue_and_store(
        c.store,
        c.root_ctx,
        parent_holder,
        [:write, :execute, :delegate],
        {:docs, [uuid]}
      )

    child =
      issue_and_store(
        c.store,
        parent_holder.ctx,
        child_holder,
        [:write],
        {:docs, [uuid]},
        parent: parent,
        allow_write_without_execute: true
      )

    assert {:ok, %{verbs: [:write], scope: {:docs, [^uuid]}}} =
             VerifyChain.verify_chain(child.id, MapSet.new([c.root_ctx.public_key]), c.store)

    assert {:error, {:trust_rejected, :capability_insufficient}} =
             write_code(c.store, uuid, "# attenuated refusal\n", child.id, child_holder.ctx)
  end

  test "pin 5: Gate-B accepts a w+x subtree-cert contributor", c do
    zone = UUID.uuid4()
    uuid = zoned_code_doc(c.store, c.root_ctx, zone)
    author = fixture_identity("gate-b-author")
    cert = issue_and_store(c.store, c.root_ctx, author, [:write, :execute], {:subtree, zone})

    assert %Commit{} = write_code(c.store, uuid, "# Gate-B contributor\n", cert.id, author.ctx)
    assert :ok = Trust.authorized_to_execute?(c.store, uuid, c.cfg)
  end

  test "pin 6: revoking the w+x subtree cert makes Gate-B refuse the same contributor", c do
    zone = UUID.uuid4()
    uuid = zoned_code_doc(c.store, c.root_ctx, zone)
    author = fixture_identity("revoked-author")
    cert = issue_and_store(c.store, c.root_ctx, author, [:write, :execute], {:subtree, zone})

    assert %Commit{} = write_code(c.store, uuid, "# soon revoked\n", cert.id, author.ctx)
    assert :ok = Trust.authorized_to_execute?(c.store, uuid, c.cfg)

    {:ok, revocation} = Capability.revoke(c.root_ctx, cert.id)
    :ok = CommitStoreClient.store_revocation(c.store, revocation)

    assert {:error, {:untrusted_contributor, _, :revoked}} =
             Trust.authorized_to_execute?(c.store, uuid, c.cfg)
  end
end

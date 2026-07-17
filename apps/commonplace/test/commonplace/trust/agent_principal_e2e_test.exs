defmodule Commonplace.Trust.AgentPrincipalE2ETest do
  @moduledoc """
  CX-88mw keystone (federate-for-real phase B acceptance): an agent as a
  first-class signing principal, end to end through the REAL import gate.

  The flow this pins down — the move-#1 invariant in miniature:

  1. A creator (human root, pinned in strict config) registers an agent
     through the substrate (`Identity.register_agent`) — the agent's
     birth-certificate commits are CREATOR-signed (decision D9).
  2. The agent's keypair is minted into SecretStore custody (D5) and its
     pubkey lands in the identity doc (D6 — convenience, not authority).
  3. The creator delegates a write-scoped capability cert to the agent's
     key (phase-3 `Capability.delegate`, the same mechanism that grants
     a federated peer-root).
  4. The agent signs a commit carrying `capability_proof` and it passes
     strict Gate A via `CommitStore.import_commit` — the same door a
     federated commit arrives through.
  5. Without a cert, or outside the cert's doc scope, the strict gate
     rejects.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{AgentKeys, Signing, SigningContext}
  alias Commonplace.Presence.Identity
  alias Commonplace.Store.{Commit, CommitStore, SecretStore}
  alias Commonplace.Tree.Schema
  alias Commonplace.Trust.Capability

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_agent_e2e_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)

    # R4c carve-out: store_capability/2 delegates to TrustSideStore, so this
    # needs the full trio (a bare CommitStore has no companion by default).
    n = :rand.uniform(1_000_000)
    store = :"agent_e2e_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"agent_e2e_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"agent_e2e_tss_#{n}",
       pending_imports_name: :"agent_e2e_pi_#{n}"}
    )

    secrets = :"agent_e2e_secrets_#{:rand.uniform(1_000_000)}"
    {:ok, secrets_pid} = SecretStore.start_link(data_dir: Path.join(dir, "secrets"), name: secrets)

    # Root schema so __identities__ has somewhere to live.
    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    CommitStore.create_commit(store, root_uuid, Yelixer.Encoding.encode_update(root_doc), nil)

    # The creator: a human root whose key is pinned in strict config.
    {creator_pub, creator_priv} = Signing.generate_keypair()
    creator_uuid = "root-" <> UUID.uuid4()

    creator_ctx = %SigningContext{
      identity_uuid: creator_uuid,
      private_key: creator_priv,
      public_key: creator_pub
    }

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{creator_uuid => Signing.encode_key(creator_pub)}
    })

    on_exit(fn ->
      Application.delete_env(:commonplace, :trust)
      if Process.alive?(secrets_pid), do: (try do GenServer.stop(secrets_pid) catch (:exit, _ -> :ok) end)
      File.rm_rf!(dir)
    end)

    %{
      store: store,
      secrets: secrets,
      root: root_uuid,
      creator: %{uuid: creator_uuid, pub: creator_pub, ctx: creator_ctx}
    }
  end

  defp register_agent!(name, ctx) do
    {:ok, agent_uuid, agent_pub} =
      Identity.register_agent(name, ctx.root, ctx.store,
        signing_context: ctx.creator.ctx,
        secret_store: ctx.secrets
      )

    %{uuid: agent_uuid, pub: agent_pub}
  end

  defp delegate!(ctx, agent, docs) do
    {:ok, cert} =
      Capability.delegate(ctx.creator.ctx, {agent.uuid, agent.pub}, %{
        verbs: [:write],
        scope: {:docs, docs},
        caveats: %{not_before: nil, not_after: nil}
      })

    :ok = CommitStore.store_capability(ctx.store, cert)
    cert
  end

  defp agent_commit(ctx, agent, doc_uuid, metadata) do
    {:ok, agent_ctx} = AgentKeys.signing_context_for(agent.uuid, ctx.secrets)
    signer_id = Signing.signer_id(agent.uuid, agent_ctx.public_key)

    Commit.new(doc_uuid, "agent payload", nil, Map.merge(%{kind: :regular}, metadata))
    |> Signing.sign_commit(agent_ctx.private_key, signer_id)
  end

  # The payload above isn't real Yjs bytes and namespace/epoch stamping
  # is not under test here — bypass the namespace validator the same way
  # capability_envelope_test does, leaving the TRUST gate fully live.
  defp import!(store, commit) do
    CommitStore.import_commit(store, commit, validator: fn _ -> :ok end)
  end

  test "keystone: registered agent with a delegated cert passes the strict import gate", ctx do
    agent = register_agent!("fable-agent", ctx)
    cert = delegate!(ctx, agent, ["fed-doc-1"])

    commit = agent_commit(ctx, agent, "fed-doc-1", %{capability_proof: cert.id})

    assert :ok = import!(ctx.store, commit)
    assert {:ok, stored} = CommitStore.get_commit(ctx.store, commit.id)
    assert stored.signer_id == Signing.signer_id(agent.uuid, agent.pub)
  end

  test "birth certificate: the agent's registration commits are creator-signed (D9)", ctx do
    agent = register_agent!("accountable-agent", ctx)

    {:ok, birth} = CommitStore.latest_commit(ctx.store, agent.uuid)
    assert birth.signer_id =~ ctx.creator.uuid

    # And the pubkey binding landed in the identity doc (D6 convenience).
    assert Base.encode64(agent.pub) in Identity.get_public_keys(agent.uuid, ctx.store)
  end

  test "no cert: the agent's signed commit is rejected as an untrusted signer", ctx do
    agent = register_agent!("certless-agent", ctx)

    commit = agent_commit(ctx, agent, "fed-doc-1", %{})

    assert {:error, {:trust_rejected, {:untrusted_signer, _}}} =
             import!(ctx.store, commit)

    assert :none = CommitStore.get_commit(ctx.store, commit.id)
  end

  test "scope narrowing: a cert for doc X does not authorize doc Y", ctx do
    agent = register_agent!("scoped-agent", ctx)
    cert = delegate!(ctx, agent, ["fed-doc-1"])

    commit = agent_commit(ctx, agent, "other-doc", %{capability_proof: cert.id})

    assert {:error, {:trust_rejected, :capability_insufficient}} =
             import!(ctx.store, commit)

    assert :none = CommitStore.get_commit(ctx.store, commit.id)
  end

  test "key theft is useless: a commit signed by a different key with the agent's cert is rejected",
       ctx do
    agent = register_agent!("victim-agent", ctx)
    cert = delegate!(ctx, agent, ["fed-doc-1"])

    # An attacker holds the (public) cert chain but not the agent's
    # private key — the ⭐ commit-author binding must reject.
    {thief_pub, thief_priv} = Signing.generate_keypair()
    thief_signer = Signing.signer_id(agent.uuid, thief_pub)

    forged =
      Commit.new("fed-doc-1", "stolen payload", nil, %{
        kind: :regular,
        capability_proof: cert.id
      })
      |> Signing.sign_commit(thief_priv, thief_signer)

    assert {:error, {:trust_rejected, :capability_author_mismatch}} =
             import!(ctx.store, forged)
  end
end

defmodule Commonplace.Trust.CertMintTest do
  use ExUnit.Case

  alias Commonplace.CertMint
  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Commonplace.Trust.Capability

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_cert_mint_#{System.unique_integer([:positive])}")
    n = System.unique_integer([:positive])
    store = :"cert_mint_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"cert_mint_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"cert_mint_tss_#{n}",
       pending_imports_name: :"cert_mint_pi_#{n}"}
    )

    on_exit(fn -> File.rm_rf!(dir) end)

    root_uuid = UUID.uuid4()
    doc_uuid = UUID.uuid4()
    seed_text(store, doc_uuid, "notes.txt", "fixture")
    seed_root(store, root_uuid, "notes.txt", doc_uuid)

    {issuer_pub, issuer_priv} = Signing.generate_keypair()

    issuer_ctx = %SigningContext{
      identity_uuid: UUID.uuid4(),
      private_key: issuer_priv,
      public_key: issuer_pub
    }

    {audience_pub, audience_priv} = Signing.generate_keypair()
    audience_uuid = UUID.uuid4()

    audience_ctx = %SigningContext{
      identity_uuid: audience_uuid,
      private_key: audience_priv,
      public_key: audience_pub
    }

    %{
      store: store,
      root_uuid: root_uuid,
      doc_uuid: doc_uuid,
      commit_cid: commit_cid(store, doc_uuid),
      issuer_ctx: issuer_ctx,
      audience: {audience_uuid, audience_pub},
      audience_ctx: audience_ctx
    }
  end

  test "all three existing scope ref forms resolve on a fixture store", ctx do
    assert {:ok, ctx.doc_uuid} ==
             CertMint.resolve_scope_ref("notes.txt", ctx.root_uuid, ctx.store)

    assert {:ok, ctx.doc_uuid} ==
             CertMint.resolve_scope_ref(":" <> ctx.doc_uuid, ctx.root_uuid, ctx.store)

    cid = Base.encode16(ctx.commit_cid, case: :lower)
    assert {:ok, ctx.doc_uuid} == CertMint.resolve_scope_ref("@" <> cid, ctx.root_uuid, ctx.store)
  end

  test "CLI-path core mint is byte-identical to the Capability.issue ceremony", ctx do
    expiry = ~U[2030-01-02 03:04:05Z]
    verbs = [:execute, :write]
    audience = ctx.audience

    assert {:ok, cli_cap} =
             CertMint.mint("notes.txt", verbs, elem(audience, 0), expiry,
               root_uuid: ctx.root_uuid,
               store: ctx.store,
               issuer_context: ctx.issuer_ctx,
               audience_resolver: fn _uuid -> {:ok, elem(audience, 1)} end
             )

    claim = %{
      verbs: verbs,
      scope: {:subtree, ctx.doc_uuid},
      caveats: %{not_before: nil, not_after: expiry}
    }

    assert {:ok, iex_cap} =
             Capability.issue(ctx.issuer_ctx, audience, claim, nil, store: ctx.store)

    assert :erlang.term_to_binary(cli_cap, [:deterministic]) ==
             :erlang.term_to_binary(iex_cap, [:deterministic])
  end

  test "a CLI-minted subtree cert delegates only with its exact root", ctx do
    audience = ctx.audience

    assert {:ok, parent} =
             CertMint.mint("notes.txt", [:write, :delegate], elem(audience, 0), nil,
               root_uuid: ctx.root_uuid,
               store: ctx.store,
               issuer_context: ctx.issuer_ctx,
               audience_resolver: fn _uuid -> {:ok, elem(audience, 1)} end
             )

    {child_pub, _} = Signing.generate_keypair()
    child_claim = %{parent.claim | verbs: [:write]}

    assert {:ok, _child} =
             Capability.issue(ctx.audience_ctx, {UUID.uuid4(), child_pub}, child_claim, parent.id,
               parent: parent,
               store: ctx.store
             )

    foreign_root_claim = %{child_claim | scope: {:subtree, UUID.uuid4()}}

    assert {:error, :subtree_scope_root_mismatch} =
             Capability.issue(
               ctx.audience_ctx,
               {UUID.uuid4(), child_pub},
               foreign_root_claim,
               parent.id,
               parent: parent,
               store: ctx.store
             )

    assert CertMint.refusal_text(:subtree_scope_root_mismatch) ==
             "cert-mint refused: subtree delegation must keep exactly the parent's root"
  end

  defp seed_root(store, root_uuid, name, doc_uuid) do
    root = Schema.new_schema() |> Schema.add_file(name, doc_uuid)
    update = Yelixer.Encoding.encode_update(root)
    %Commonplace.Store.Commit{} = CommitStore.create_commit(store, root_uuid, update, nil, %{})
  end

  defp seed_text(store, uuid, name, body) do
    doc = Yelixer.Doc.new() |> ContentType.create(:text, name)
    doc = ContentType.insert_text(doc, 0, body)
    update = Yelixer.Encoding.encode_update(doc)
    %Commonplace.Store.Commit{} = CommitStore.create_commit(store, uuid, update, nil, %{})
  end

  defp commit_cid(store, uuid) do
    {:ok, commit} = CommitStore.latest_commit(store, uuid)
    commit.id
  end
end

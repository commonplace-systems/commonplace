defmodule Commonplace.Trust.CapabilityTest do
  @moduledoc """
  CX-tdkq.22a (phase 3): the capability cert VALUE type. A UCAN-shaped,
  issuer-signed, content-addressed delegation. Mirrors Store.Commit's
  content-addressing discipline: the id is sha256 over the canonical
  assertion EXCLUDING the signature, so a signature over the id
  transitively covers every meaningful field, and two nodes minting the
  same cert converge on the same CID.

  Binding is full-pubkey (the 8-char fingerprint is 2^32 second-preimage
  forgeable), so issuer/audience carry the full 32-byte key.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Trust.{Capability, CodeDocHeuristic}

  setup do
    {ipub, ipriv} = Signing.generate_keypair()
    {apub, _apriv} = Signing.generate_keypair()
    issuer = {"root-id", ipub}
    audience = {"alice-id", apub}
    issuer_ctx = %SigningContext{identity_uuid: "root-id", private_key: ipriv, public_key: ipub}

    claim = %{
      verbs: [:write, :delegate],
      scope: {:docs, ["doc-a", "doc-b"]},
      caveats: %{not_before: nil, not_after: nil}
    }

    %{
      issuer: issuer,
      audience: audience,
      issuer_ctx: issuer_ctx,
      claim: claim,
      ipub: ipub,
      ipriv: ipriv,
      apub: apub
    }
  end

  describe "new/4 + content addressing" do
    test "mints a struct with a binary CID", ctx do
      cap = Capability.new(ctx.issuer, ctx.audience, ctx.claim, nil)
      assert is_binary(cap.id)
      assert cap.proof == nil
      assert cap.sig == nil
    end

    test "verify_id accepts a well-formed cert", ctx do
      cap = Capability.new(ctx.issuer, ctx.audience, ctx.claim, nil)
      assert :ok = Capability.verify_id(cap)
    end

    test "verify_id rejects a tampered claim", ctx do
      cap = Capability.new(ctx.issuer, ctx.audience, ctx.claim, nil)
      tampered = %{cap | claim: put_in(cap.claim.verbs, [:write, :delegate, :execute])}

      assert :ok = Capability.verify_id(cap),
             "precondition: the untampered capability exists and verifies"

      assert {:error, {:id_mismatch, _, _}} = Capability.verify_id(tampered)
    end

    test "verify_id rejects a swapped audience (key-binding is in the id)", ctx do
      cap = Capability.new(ctx.issuer, ctx.audience, ctx.claim, nil)
      {other, _} = Signing.generate_keypair()
      tampered = %{cap | audience: {"alice-id", other}}

      assert :ok = Capability.verify_id(cap),
             "precondition: the capability exists and verifies before its audience is swapped"

      assert {:error, {:id_mismatch, _, _}} = Capability.verify_id(tampered)
    end
  end

  describe "CID determinism" do
    test "same inputs → same CID across independent mints", ctx do
      c1 = Capability.new(ctx.issuer, ctx.audience, ctx.claim, nil)
      c2 = Capability.new(ctx.issuer, ctx.audience, ctx.claim, nil)
      assert c1.id == c2.id
    end

    test "scope/verb ORDER does not change the CID (canonical sorting)", ctx do
      reordered = %{ctx.claim | verbs: [:delegate, :write], scope: {:docs, ["doc-b", "doc-a"]}}
      c1 = Capability.new(ctx.issuer, ctx.audience, ctx.claim, nil)
      c2 = Capability.new(ctx.issuer, ctx.audience, reordered, nil)
      assert c1.id == c2.id
    end

    test "duplicate scope/verb entries are normalized out", ctx do
      dup = %{
        ctx.claim
        | verbs: [:write, :write, :delegate],
          scope: {:docs, ["doc-a", "doc-a", "doc-b"]}
      }

      c1 = Capability.new(ctx.issuer, ctx.audience, ctx.claim, nil)
      c2 = Capability.new(ctx.issuer, ctx.audience, dup, nil)
      assert c1.id == c2.id
    end

    test "a different proof changes the CID", ctx do
      c1 = Capability.new(ctx.issuer, ctx.audience, ctx.claim, nil)
      c2 = Capability.new(ctx.issuer, ctx.audience, ctx.claim, <<1, 2, 3>>)

      assert Capability.verify_id(c1) == :ok and Capability.verify_id(c2) == :ok,
             "precondition: both independently minted capabilities exist and verify"

      refute c1.id == c2.id
    end
  end

  describe "sign/2 + verify_sig/2" do
    test "sign sets sig without changing the id", ctx do
      cap = Capability.new(ctx.issuer, ctx.audience, ctx.claim, nil)
      signed = Capability.sign(cap, ctx.ipriv)
      assert signed.sig != nil
      assert signed.id == cap.id
      assert :ok = Capability.verify_id(signed)
    end

    test "verify_sig succeeds against the issuer key", ctx do
      signed =
        Capability.new(ctx.issuer, ctx.audience, ctx.claim, nil) |> Capability.sign(ctx.ipriv)

      assert :ok = Capability.verify_sig(signed)
    end

    test "verify_sig fails when issuer.pubkey doesn't match the signing key", ctx do
      {_other_pub, other_priv} = Signing.generate_keypair()
      # Signed by the wrong key — issuer still claims ipub, so verify fails.
      signed =
        Capability.new(ctx.issuer, ctx.audience, ctx.claim, nil) |> Capability.sign(other_priv)

      assert :ok = Capability.verify_id(signed),
             "precondition: the wrong-key-signed capability exists with a valid content id"

      assert {:error, :invalid_signature} = Capability.verify_sig(signed)
    end

    test "verify_sig errors on an unsigned cert", ctx do
      cap = Capability.new(ctx.issuer, ctx.audience, ctx.claim, nil)

      assert :ok = Capability.verify_id(cap),
             "precondition: the unsigned capability exists with a valid content id"

      assert {:error, :unsigned} = Capability.verify_sig(cap)
    end
  end

  describe "issue/5 — mint with narrowing validation" do
    # Helper: a fresh identity with its signing context.
    defp ident(id) do
      {pub, priv} = Signing.generate_keypair()
      {{id, pub}, %SigningContext{identity_uuid: id, private_key: priv, public_key: pub}}
    end

    test "root issue (parent nil) signs with the issuer context", ctx do
      {audience, _} = ident("alice-id")
      assert {:ok, cap} = Capability.issue(ctx.issuer_ctx, audience, ctx.claim, nil)
      assert {"root-id", _} = cap.issuer
      assert cap.audience == audience
      assert :ok = Capability.verify_sig(cap)
    end

    test "delegation with a narrower claim succeeds", ctx do
      {alice, alice_ctx} = ident("alice-id")
      {bob, _} = ident("bob-id")
      {:ok, parent} = Capability.issue(ctx.issuer_ctx, alice, ctx.claim, nil)

      child_claim = %{
        verbs: [:write],
        scope: {:docs, ["doc-a"]},
        caveats: %{not_before: nil, not_after: nil}
      }

      assert {:ok, child} =
               Capability.issue(alice_ctx, bob, child_claim, parent.id, parent: parent)

      assert child.proof == parent.id
      assert :ok = Capability.verify_sig(child)
    end

    test "delegation rejects a child that EXCEEDS the parent (extra verb)", ctx do
      {alice, alice_ctx} = ident("alice-id")
      {bob, _} = ident("bob-id")
      {:ok, parent} = Capability.issue(ctx.issuer_ctx, alice, ctx.claim, nil)

      wider = %{
        verbs: [:write, :delegate, :execute],
        scope: {:docs, ["doc-a"]},
        caveats: %{not_before: nil, not_after: nil}
      }

      assert Capability.verify_id(parent) == :ok and Capability.verify_sig(parent) == :ok,
             "precondition: the parent capability exists and verifies before wider verbs are delegated"

      assert {:error, {:not_attenuation, _}} =
               Capability.issue(alice_ctx, bob, wider, parent.id, parent: parent)
    end

    test "delegation rejects a child whose scope exceeds the parent", ctx do
      {alice, alice_ctx} = ident("alice-id")
      {bob, _} = ident("bob-id")
      {:ok, parent} = Capability.issue(ctx.issuer_ctx, alice, ctx.claim, nil)

      wider = %{
        verbs: [:write],
        scope: {:docs, ["doc-a", "doc-c"]},
        caveats: %{not_before: nil, not_after: nil}
      }

      assert Capability.verify_id(parent) == :ok and Capability.verify_sig(parent) == :ok,
             "precondition: the parent capability exists and verifies before a wider scope is delegated"

      assert {:error, {:not_attenuation, _}} =
               Capability.issue(alice_ctx, bob, wider, parent.id, parent: parent)
    end
  end

  describe "mint-time write-without-execute guard (CX-tdkq.28)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "cp_capguard_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      name = :"capguard_store_#{:rand.uniform(1_000_000)}"
      start_supervised!({Commonplace.Store.CommitStore, data_dir: dir, name: name})
      on_exit(fn -> File.rm_rf!(dir) end)

      code_uuid = "aaaaaaaa-0000-0000-0000-000000000001"
      data_uuid = "bbbbbbbb-0000-0000-0000-000000000002"
      seed_text(name, code_uuid, "_renderer.ex", "defmodule Guard.Foo do\n  def x, do: 1\nend\n")
      seed_text(name, data_uuid, "notes", "just some prose, not code")

      %{store: name, code_uuid: code_uuid, data_uuid: data_uuid}
    end

    test "refuses write-without-execute scoped to a code doc", ctx do
      c = ctx.code_uuid
      claim = %{verbs: [:write], scope: {:docs, [c]}, caveats: %{not_before: nil, not_after: nil}}

      assert CodeDocHeuristic.code_doc?(c, ctx.store),
             "precondition: the scoped document exists and is classified as code"

      assert {:error, {:write_without_execute_on_code_doc, ^c}} =
               Capability.issue(ctx.issuer_ctx, ctx.audience, claim, nil, store: ctx.store)
    end

    test "allows write-without-execute on a non-code doc", ctx do
      claim = %{
        verbs: [:write],
        scope: {:docs, [ctx.data_uuid]},
        caveats: %{not_before: nil, not_after: nil}
      }

      assert {:ok, _} =
               Capability.issue(ctx.issuer_ctx, ctx.audience, claim, nil, store: ctx.store)
    end

    test "allows write+execute on a code doc", ctx do
      claim = %{
        verbs: [:write, :execute],
        scope: {:docs, [ctx.code_uuid]},
        caveats: %{not_before: nil, not_after: nil}
      }

      assert {:ok, _} =
               Capability.issue(ctx.issuer_ctx, ctx.audience, claim, nil, store: ctx.store)
    end

    test "override flag allows write-without-execute on a code doc", ctx do
      claim = %{
        verbs: [:write],
        scope: {:docs, [ctx.code_uuid]},
        caveats: %{not_before: nil, not_after: nil}
      }

      assert {:ok, _} =
               Capability.issue(ctx.issuer_ctx, ctx.audience, claim, nil,
                 store: ctx.store,
                 allow_write_without_execute: true
               )
    end

    test "delegate inherits the guard", ctx do
      # Parent grants write+execute on the code doc; the delegation narrows to
      # write-only on the same code doc → refused at mint (delegate funnels to issue).
      parent_claim = %{
        verbs: [:write, :execute],
        scope: {:docs, [ctx.code_uuid]},
        caveats: %{not_before: nil, not_after: nil}
      }

      {:ok, parent} =
        Capability.issue(ctx.issuer_ctx, ctx.audience, parent_claim, nil, store: ctx.store)

      {_child, child_ctx} = ident("delegatee-id")

      narrowed = %{
        verbs: [:write],
        scope: {:docs, [ctx.code_uuid]},
        caveats: %{not_before: nil, not_after: nil}
      }

      assert Capability.verify_id(parent) == :ok and Capability.verify_sig(parent) == :ok and
               CodeDocHeuristic.code_doc?(ctx.code_uuid, ctx.store),
             "precondition: the parent verifies and its populated scope contains a code document"

      assert {:error, {:write_without_execute_on_code_doc, _}} =
               Capability.delegate(child_ctx, ctx.audience, narrowed, parent.id,
                 parent: parent,
                 store: ctx.store
               )
    end
  end

  describe "CX-0a9a presence-carve (W1): {:presence, identity_uuid} scope" do
    test "new/4 accepts and normalizes a presence scope (identity uuid unchanged, no list-sort)",
         ctx do
      claim = %{verbs: [:write], scope: {:presence, "identity-123"}, caveats: %{}}
      cap = Capability.new(ctx.issuer, ctx.audience, claim, nil)
      assert cap.claim.scope == {:presence, "identity-123"}
      assert is_binary(cap.id)
    end

    test "same {:presence, id} claim mints the same CID across independent mints", ctx do
      claim = %{verbs: [:write], scope: {:presence, "identity-123"}, caveats: %{}}
      c1 = Capability.new(ctx.issuer, ctx.audience, claim, nil)
      c2 = Capability.new(ctx.issuer, ctx.audience, claim, nil)
      assert c1.id == c2.id
    end

    test "a different presence identity_uuid changes the CID", ctx do
      claim_a = %{verbs: [:write], scope: {:presence, "identity-a"}, caveats: %{}}
      claim_b = %{verbs: [:write], scope: {:presence, "identity-b"}, caveats: %{}}
      c1 = Capability.new(ctx.issuer, ctx.audience, claim_a, nil)
      c2 = Capability.new(ctx.issuer, ctx.audience, claim_b, nil)

      assert Capability.verify_id(c1) == :ok and Capability.verify_id(c2) == :ok,
             "precondition: both presence-scoped capabilities exist and verify"

      refute c1.id == c2.id
    end

    test "issue/5 mints+signs a root presence-scoped cert with no parent", ctx do
      {audience, _} = ident_helper("bot-id")
      claim = %{verbs: [:write], scope: {:presence, "identity-123"}, caveats: %{}}
      assert {:ok, cap} = Capability.issue(ctx.issuer_ctx, audience, claim, nil)
      assert cap.claim.scope == {:presence, "identity-123"}
      assert :ok = Capability.verify_sig(cap)
    end

    test "issue/5 does NOT refuse write-without-execute on a presence scope (no code-doc risk)",
         ctx do
      {audience, _} = ident_helper("bot-id")
      claim = %{verbs: [:write], scope: {:presence, "identity-123"}, caveats: %{}}
      # No :store passed at all — if check_no_code_doc_in_scope tried to
      # treat this as {:docs, _}, it would crash on the pattern match
      # rather than just failing the code-doc check.
      assert {:ok, _cap} = Capability.issue(ctx.issuer_ctx, audience, claim, nil)
    end

    defp ident_helper(id) do
      {pub, priv} = Signing.generate_keypair()
      {{id, pub}, %SigningContext{identity_uuid: id, private_key: priv, public_key: pub}}
    end
  end

  defp seed_text(store, uuid, name, body) do
    doc = Yelixer.Doc.new() |> Commonplace.Document.ContentType.create(:text, name)
    doc = Commonplace.Document.ContentType.insert_text(doc, 0, body)
    update = Yelixer.Encoding.encode_update(doc)
    Commonplace.Store.CommitStore.create_commit(store, uuid, update, nil, %{})
  end
end

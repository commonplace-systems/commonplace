defmodule Commonplace.Trust.DefineVerbGateTest do
  @moduledoc """
  CX-ndvi §1.1/§5/§6 pin 6 — `Commonplace.Trust.DefineVerbGate` (the
  `:define_verb` contributor walk) and `Commonplace.Code.SourceDoc`'s
  `{:verb, section_scope}` gate class that calls it. Mirrors
  `Commonplace.Code.ExecuteGateTest`'s permissive/strict/laundering
  shape, and `Commonplace.MUD.SectionOwnershipTest`'s named-store +
  capability-cert setup (needed here because, unlike Gate B's plain
  signed/unsigned cases, several of these pins exercise a
  `:define_verb`-scoped capability cert, which requires the full
  named-store trio's trust-side store — a bare `CommitStore` child alone
  isn't enough, see CX-ziye).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Code.SourceDoc
  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Trust.{Capability, DefineVerbGate}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_define_gate_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"dvg_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"dvg_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"dvg_tss_#{n}",
       pending_imports_name: :"dvg_pi_#{n}"}
    )

    old_trust = Application.get_env(:commonplace, :trust)

    on_exit(fn ->
      case old_trust do
        nil -> Application.delete_env(:commonplace, :trust)
        v -> Application.put_env(:commonplace, :trust, v)
      end

      File.rm_rf!(dir)
    end)

    SourceDoc.reset_cache()

    {owner_pub, owner_priv} = Signing.generate_keypair()
    owner_identity = "def0000-#{:rand.uniform(999_999_999_999)}"
    owner_ctx = %SigningContext{identity_uuid: owner_identity, private_key: owner_priv, public_key: owner_pub}

    {stranger_pub, stranger_priv} = Signing.generate_keypair()
    stranger_identity = "def1111-#{:rand.uniform(999_999_999_999)}"

    stranger_ctx = %SigningContext{
      identity_uuid: stranger_identity,
      private_key: stranger_priv,
      public_key: stranger_pub
    }

    section_uuid = UUID.uuid4()

    %{
      store: store,
      owner_identity: owner_identity,
      owner_pub: owner_pub,
      owner_ctx: owner_ctx,
      stranger_identity: stranger_identity,
      stranger_ctx: stranger_ctx,
      section_uuid: section_uuid
    }
  end

  defp strict!(trusted) do
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: trusted})
  end

  defp verb_source(n) do
    """
    defmodule Commonplace.MUD.SafeVerbBody#{n} do
      def run(_world, _args), do: :verb_#{n}
    end
    """
  end

  defp encode_source_doc(source_string) do
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, "verb")
    doc = ContentType.insert_text(doc, 0, source_string)
    Yelixer.Encoding.encode_update(doc)
  end

  defp mint(store, source_string, opts) do
    uuid = UUID.uuid4()
    update = encode_source_doc(source_string)
    CommitStore.create_chained_commit(store, uuid, update, %{kind: :regular}, opts)
    uuid
  end

  defp append_commit(store, uuid, source_string, opts) do
    update = encode_source_doc(source_string)
    CommitStore.create_chained_commit(store, uuid, update, %{kind: :regular}, opts)
  end

  defp issue_define_cap(store, issuer_ctx, audience, section_uuids, verbs) do
    claim = %{verbs: verbs, scope: {:docs, section_uuids}, caveats: %{}}
    {:ok, cap} = Capability.issue(issuer_ctx, audience, claim, nil, store: store)
    :ok = CommitStoreClient.store_capability(store, cap)
    cap
  end

  test "permissive default: an unsigned verb doc compiles (status quo)", %{store: store, section_uuid: section} do
    uuid = mint(store, verb_source(1), [])
    assert {:ok, mod} = SourceDoc.compile(uuid, store, gate: {:verb, [section]})
    assert mod.run(nil, nil) == :verb_1
  end

  test "strict + owner holds :define_verb over the section → compiles", %{
    store: store,
    owner_identity: owner_identity,
    owner_pub: owner_pub,
    owner_ctx: owner_ctx,
    section_uuid: section
  } do
    strict!(%{owner_identity => Signing.encode_key(owner_pub)})

    # Owner is a locally-pinned trusted identity — the degenerate
    # unattenuated-root fast path (no capability needed at all, same as
    # Gate B for a pinned identity).
    uuid = mint(store, verb_source(2), signing_context: owner_ctx)

    assert {:ok, mod} = SourceDoc.compile(uuid, store, gate: {:verb, [section]})
    assert mod.run(nil, nil) == :verb_2
  end

  test "strict + a signed-but-uncapped stranger is DENIED (not a define-authority holder)", %{
    store: store,
    owner_identity: owner_identity,
    owner_pub: owner_pub,
    stranger_ctx: stranger_ctx,
    section_uuid: section
  } do
    strict!(%{owner_identity => Signing.encode_key(owner_pub)})

    uuid = mint(store, verb_source(3), signing_context: stranger_ctx)

    assert {:error, {:execution_denied, {:undefined_contributor, _id, _reason}}} =
             SourceDoc.compile(uuid, store, gate: {:verb, [section]})
  end

  test "a :write-only section cert (no :define_verb) does NOT authorize the define-walk", %{
    store: store,
    owner_identity: owner_identity,
    owner_pub: owner_pub,
    owner_ctx: owner_ctx,
    stranger_ctx: stranger_ctx,
    section_uuid: section
  } do
    strict!(%{owner_identity => Signing.encode_key(owner_pub)})

    cap =
      issue_define_cap(store, owner_ctx, {stranger_ctx.identity_uuid, stranger_ctx.public_key}, [section], [
        :write
      ])

    uuid = UUID.uuid4()

    CommitStore.create_chained_commit(
      store,
      uuid,
      encode_source_doc(verb_source(4)),
      %{kind: :regular, capability_proof: cap.id},
      signing_context: stranger_ctx
    )

    assert {:error, {:execution_denied, {:undefined_contributor, _id, :capability_insufficient}}} =
             SourceDoc.compile(uuid, store, gate: {:verb, [section]})
  end

  test "an explicit [:define_verb]-scoped delegate cert authorizes the define-walk", %{
    store: store,
    owner_identity: owner_identity,
    owner_pub: owner_pub,
    owner_ctx: owner_ctx,
    stranger_ctx: stranger_ctx,
    section_uuid: section
  } do
    strict!(%{owner_identity => Signing.encode_key(owner_pub)})

    cap =
      issue_define_cap(store, owner_ctx, {stranger_ctx.identity_uuid, stranger_ctx.public_key}, [section], [
        :define_verb
      ])

    uuid = UUID.uuid4()

    CommitStore.create_chained_commit(
      store,
      uuid,
      encode_source_doc(verb_source(5)),
      %{kind: :regular, capability_proof: cap.id},
      signing_context: stranger_ctx
    )

    assert {:ok, mod} = SourceDoc.compile(uuid, store, gate: {:verb, [section]})
    assert mod.run(nil, nil) == :verb_5
  end

  test "laundering is caught: trusted head, untrusted earlier contributor", %{
    store: store,
    owner_identity: owner_identity,
    owner_pub: owner_pub,
    owner_ctx: owner_ctx,
    section_uuid: section
  } do
    strict!(%{owner_identity => Signing.encode_key(owner_pub)})

    uuid = mint(store, verb_source(6), [])
    append_commit(store, uuid, verb_source(6) <> "# owner edit\n", signing_context: owner_ctx)

    assert {:error, {:execution_denied, {:undefined_contributor, _id, :unsigned}}} =
             SourceDoc.compile(uuid, store, gate: {:verb, [section]})
  end

  test "revoked definer's verb stops dispatching (verify-time, CX-bepn P1)", %{
    store: store,
    owner_identity: owner_identity,
    owner_pub: owner_pub,
    owner_ctx: owner_ctx,
    stranger_ctx: stranger_ctx,
    section_uuid: section
  } do
    strict!(%{owner_identity => Signing.encode_key(owner_pub)})

    cap =
      issue_define_cap(store, owner_ctx, {stranger_ctx.identity_uuid, stranger_ctx.public_key}, [section], [
        :define_verb
      ])

    uuid = UUID.uuid4()

    CommitStore.create_chained_commit(
      store,
      uuid,
      encode_source_doc(verb_source(7)),
      %{kind: :regular, capability_proof: cap.id},
      signing_context: stranger_ctx
    )

    assert {:ok, _mod} = SourceDoc.compile(uuid, store, gate: {:verb, [section]})

    # Revoke — the stranger's define authority is now void.
    {:ok, revocation} = Capability.revoke(owner_ctx, cap.id)
    :ok = CommitStoreClient.store_revocation(store, revocation)

    SourceDoc.reset_cache()

    assert {:error, {:execution_denied, {:undefined_contributor, _id, :revoked}}} =
             SourceDoc.compile(uuid, store, gate: {:verb, [section]})
  end

  test "the default :execute gate is completely unaffected by :define_verb-only authority", %{
    store: store,
    owner_identity: owner_identity,
    owner_pub: owner_pub,
    owner_ctx: owner_ctx,
    section_uuid: section
  } do
    strict!(%{owner_identity => Signing.encode_key(owner_pub)})

    cap =
      issue_define_cap(store, owner_ctx, {owner_ctx.identity_uuid, owner_ctx.public_key}, [section], [
        :define_verb
      ])

    uuid = UUID.uuid4()

    CommitStore.create_chained_commit(
      store,
      uuid,
      encode_source_doc(verb_source(8)),
      %{kind: :regular, capability_proof: cap.id},
      signing_context: owner_ctx
    )

    # owner IS a pinned trusted identity, so the default :execute gate
    # (unrelated to :define_verb) still succeeds via the degenerate
    # pinned-root path — proving the two gate classes are independent
    # checks, not aliases of one another.
    assert {:ok, mod} = SourceDoc.compile(uuid, store)
    assert mod.run(nil, nil) == :verb_8
  end

  describe "DefineVerbGate.authorized_to_define?/4 directly" do
    test "empty section_scope denies with :empty_section_scope reason", %{
      store: store,
      owner_identity: owner_identity,
      owner_pub: owner_pub,
      stranger_ctx: stranger_ctx
    } do
      strict!(%{owner_identity => Signing.encode_key(owner_pub)})

      uuid = UUID.uuid4()

      CommitStore.create_chained_commit(
        store,
        uuid,
        encode_source_doc(verb_source(9)),
        %{kind: :regular},
        signing_context: stranger_ctx
      )

      assert {:error, {:undefined_contributor, _id, :empty_section_scope}} =
               DefineVerbGate.authorized_to_define?(store, uuid, [])
    end
  end
end

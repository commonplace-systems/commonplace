defmodule Commonplace.MUD.SignedWriteTest do
  @moduledoc """
  CX-0a9a (presence-carve, W5): `SignedWrite.opts_for/2`'s cert
  selection now tries a `{:docs}` cert covering the target FIRST
  (unchanged behavior), and — only when none matches — opportunistically
  attaches a `{:presence, _}` cert the session holds. Safety of the
  fallback rests on the content-check at verify time (W3,
  `Commonplace.Trust.grants?/5`'s presence clause) — this module is pure
  selection plumbing and doesn't (and shouldn't) re-derive that.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.MUD.SignedWrite
  alias Commonplace.Store.Supervisor, as: StoreSupervisor
  alias Commonplace.Trust.Capability

  # R4c carve-out: store_capability/2 delegates to TrustSideStore, so this
  # needs the full trio (a bare CommitStore has no companion by default).
  setup do
    dir = Path.join(System.tmp_dir!(), "cp_signedwrite_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000)
    name = :"sw_store_#{n}"

    start_supervised!(
      {StoreSupervisor,
       data_dir: dir,
       name: :"sw_sup_#{n}",
       commit_store_name: name,
       trust_side_store_name: :"sw_tss_#{n}",
       pending_imports_name: :"sw_pi_#{n}"}
    )

    on_exit(fn -> File.rm_rf!(dir) end)

    {pub, priv} = Signing.generate_keypair()
    issuer_ctx = %SigningContext{identity_uuid: "root-id", private_key: priv, public_key: pub}
    audience = {"bot-id", pub}

    %{store: name, issuer_ctx: issuer_ctx, audience: audience}
  end

  defp mint_and_store(ctx, claim) do
    {:ok, cap} = Capability.issue(ctx.issuer_ctx, ctx.audience, claim)
    :ok = Commonplace.Store.CommitStoreClient.store_capability(ctx.store, cap)
    cap
  end

  describe "find_cert (via opts_for/2) — {:docs}-first, {:presence}-fallback" do
    test "returns the {:docs} cert when it covers the target", ctx do
      docs_cap = mint_and_store(ctx, %{verbs: [:write], scope: {:docs, ["target-uuid"]}, caveats: %{}})

      {metadata, _commit_opts} =
        SignedWrite.opts_for("target-uuid",
          signing_context: ctx.issuer_ctx,
          cert_cids: [docs_cap.id],
          store: ctx.store
        )

      assert metadata.capability_proof == docs_cap.id
    end

    test "falls back to a held {:presence} cert when no {:docs} cert matches", ctx do
      presence_cap = mint_and_store(ctx, %{verbs: [:write], scope: {:presence, "bot-id"}, caveats: %{}})

      {metadata, _commit_opts} =
        SignedWrite.opts_for("some-other-target-uuid",
          signing_context: ctx.issuer_ctx,
          cert_cids: [presence_cap.id],
          store: ctx.store
        )

      assert metadata.capability_proof == presence_cap.id
    end

    test "{:docs} cert wins even when a {:presence} cert is also held (docs-first)", ctx do
      docs_cap = mint_and_store(ctx, %{verbs: [:write], scope: {:docs, ["target-uuid"]}, caveats: %{}})
      presence_cap = mint_and_store(ctx, %{verbs: [:write], scope: {:presence, "bot-id"}, caveats: %{}})

      {metadata, _commit_opts} =
        SignedWrite.opts_for("target-uuid",
          signing_context: ctx.issuer_ctx,
          cert_cids: [presence_cap.id, docs_cap.id],
          store: ctx.store
        )

      assert metadata.capability_proof == docs_cap.id
    end

    test "no {:docs} match and no {:presence} cert held → no capability_proof attached", ctx do
      docs_cap = mint_and_store(ctx, %{verbs: [:write], scope: {:docs, ["unrelated-uuid"]}, caveats: %{}})

      {metadata, _commit_opts} =
        SignedWrite.opts_for("target-uuid",
          signing_context: ctx.issuer_ctx,
          cert_cids: [docs_cap.id],
          store: ctx.store
        )

      refute Map.has_key?(metadata, :capability_proof)
    end
  end
end

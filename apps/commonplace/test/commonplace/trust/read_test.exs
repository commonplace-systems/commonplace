defmodule Commonplace.Trust.ReadTest do
  @moduledoc """
  CX-sqb6 (read-scoping P1) — the `:read` gate: `Commonplace.Trust.Read` +
  `Trust.reader_authorized?`. Covers the build-brief §Tests security
  properties:

    * NO-READ-REGRESSION — a `public` (or visibility-absent) target reads for
      anyone (short-circuit).
    * self-read — the owner reads their own view-doc.
    * spectate-denied (W1) — a principal with no `:read` cap is denied.
    * spectate-granted + revoke — a granted cap allows; revoking it (CX-bepn,
      verify-time) denies again.
    * capability-theft (THE audience-binding nuance) — presenting a cap issued
      to SOMEONE ELSE's key is denied (bound to the reader's key).
    * forge-public (W3) — a reader cannot flip a view-doc's `visibility` to
      `public` (protected node-signed field, write-gated under enforce).

  Uses the full Store trio (CommitStore + TrustSideStore companion) so
  capabilities/revocations persist. Owner `A` is pinned trusted so its root
  `:read` grants chain-verify; `B`/`C` are unpinned spectators.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.MUD.SessionView
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Trust.{Capability, Read}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_read_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"read_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"read_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"read_tss_#{n}",
       pending_imports_name: :"read_pi_#{n}"}
    )

    old_data = Application.get_env(:commonplace, :data_dir)
    old_trust = Application.get_env(:commonplace, :trust)
    old_gate = Application.get_env(:commonplace, :local_write_gate)
    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    a = fresh_identity("aaaa")
    b = fresh_identity("bbbb")
    c = fresh_identity("cccc")

    # Enforce, with owner A pinned trusted (so A's root :read caps chain-verify).
    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{a.id => Signing.encode_key(a.pub)}
    })

    on_exit(fn ->
      restore = fn key, v ->
        if is_nil(v), do: Application.delete_env(:commonplace, key), else: Application.put_env(:commonplace, key, v)
      end

      restore.(:data_dir, old_data)
      restore.(:trust, old_trust)
      restore.(:local_write_gate, old_gate)
      File.rm_rf!(dir)
    end)

    # A mints their view-doc (owner = A, A-signed, capability_gated).
    view = SessionView.new(a.id, store, signing_context: a.ctx)

    %{a: a, b: b, c: c, view_uuid: view.uuid, store: store}
  end

  defp fresh_identity(tag) do
    {pub, priv} = Signing.generate_keypair()
    id = "#{tag}0000-0000-0000-0000-#{:rand.uniform(999_999_999_999)}"
    %{id: id, pub: pub, priv: priv, ctx: %SigningContext{identity_uuid: id, public_key: pub, private_key: priv}}
  end

  # The view-doc's carried protected fields (via SessionView.read_meta) + the
  # reader's presented creds → Read.authorized? opts.
  defp read_opts(ctx, reader) do
    {:ok, meta} = SessionView.read_meta(ctx.view_uuid, ctx.store)
    [visibility: meta.visibility, owner: meta.owner, reader_pub: reader.pub, store: ctx.store]
  end

  # --- no-read-regression (CRITICAL) ---

  test "no-read-regression: a public target reads for ANY principal (short-circuit)", %{b: b, store: store} do
    assert :ok = Read.authorized?(b.id, UUID.uuid4(), visibility: :public, reader_pub: b.pub, store: store)
    # visibility ABSENT (a legacy / non-opted doc) also defaults public.
    assert :ok = Read.authorized?(b.id, UUID.uuid4(), reader_pub: b.pub, store: store)
  end

  test "the minted view-doc carries capability_gated + owner", %{a: a, view_uuid: v, store: store} do
    assert {:ok, %{visibility: :capability_gated, owner: owner}} = SessionView.read_meta(v, store)
    assert owner == a.id
  end

  # --- self-read ---

  test "self-read: the owner reads their OWN view-doc", %{a: a} = ctx do
    assert :ok = Read.authorized?(a.id, ctx.view_uuid, read_opts(ctx, a) ++ [cert_cids: []])
  end

  # --- spectate-denied (W1) ---

  test "spectate-denied (W1): a principal with NO :read cap is denied", %{b: b} = ctx do
    assert {:error, :read_denied} =
             Read.authorized?(b.id, ctx.view_uuid, read_opts(ctx, b) ++ [cert_cids: []])
  end

  # --- spectate-granted + revoke ---

  test "spectate-granted then REVOKED: grant allows B, revoke denies again (verify-time)",
       %{a: a, b: b, store: store} = ctx do
    {:ok, cap} = Read.grant(a.ctx, ctx.view_uuid, {b.id, b.pub}, store: store)

    assert :ok = Read.authorized?(b.id, ctx.view_uuid, read_opts(ctx, b) ++ [cert_cids: [cap.id]])

    {:ok, rev} = Capability.revoke(a.ctx, cap.id)
    :ok = CommitStoreClient.store_revocation(store, rev)

    assert {:error, :read_denied} =
             Read.authorized?(b.id, ctx.view_uuid, read_opts(ctx, b) ++ [cert_cids: [cap.id]])
  end

  # --- capability-theft (THE audience-binding nuance, Opus) ---

  test "capability-theft: B presenting a cap whose audience is C is DENIED", %{a: a, b: b, c: c, store: store} = ctx do
    {:ok, cap_for_c} = Read.grant(a.ctx, ctx.view_uuid, {c.id, c.pub}, store: store)

    # C (the rightful audience) can use it.
    assert :ok = Read.authorized?(c.id, ctx.view_uuid, read_opts(ctx, c) ++ [cert_cids: [cap_for_c.id]])

    # B STEALS it — presents C's cap but authenticates with B's OWN key. The
    # audience binding (audience_pub == reader_pub) fails → denied.
    assert {:error, :read_denied} =
             Read.authorized?(b.id, ctx.view_uuid, read_opts(ctx, b) ++ [cert_cids: [cap_for_c.id]])
  end

  # --- forge-public (W3) ---

  test "forge-public (W3): a reader cannot flip the view-doc's visibility to public", %{b: b, store: store} = ctx do
    doc =
      Commonplace.Tree.DocBuilder.reconstruct_doc(store, ctx.view_uuid)
      |> elem(1)
      |> Yelixer.Types.XMLElement.set_attribute("view", "visibility", "public")

    update = Yelixer.Encoding.encode_update(doc)

    result =
      CommitStoreClient.create_chained_commit(store, ctx.view_uuid, update, %{kind: :regular},
        signing_context: b.ctx
      )

    # The write is refused under enforce (B is untrusted for this doc)…
    assert match?({:error, _}, result)
    # …and the visibility remains capability_gated.
    assert {:ok, %{visibility: :capability_gated}} = SessionView.read_meta(ctx.view_uuid, store)
  end

  # --- CX-73a3 P3: the local_read_gate stance-aware gate/3 ---

  describe "gate/3 (local_read_gate stance)" do
    setup do
      old = Application.get_env(:commonplace, :local_read_gate)
      on_exit(fn ->
        if is_nil(old),
          do: Application.delete_env(:commonplace, :local_read_gate),
          else: Application.put_env(:commonplace, :local_read_gate, old)
      end)

      # a would-DENY situation: gated doc, stranger reader, no owner-match/caps
      deny_opts = [surface: :test, visibility: :capability_gated, owner: "owner-x"]
      %{deny: fn -> Read.gate("stranger", UUID.uuid4(), deny_opts) end}
    end

    test "permissive: always :ok (no-regression default)", %{deny: deny} do
      Application.put_env(:commonplace, :local_read_gate, :permissive)
      assert :ok = deny.()
      # unset also defaults permissive
      Application.delete_env(:commonplace, :local_read_gate)
      assert :ok = deny.()
    end

    test "dry_run: would-deny still serves + emits would_refuse telemetry", %{deny: deny} do
      Application.put_env(:commonplace, :local_read_gate, :dry_run)
      handler = "wr-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:commonplace, :trust, :read, :would_refuse],
        fn _e, _m, meta, _ -> send(test_pid, {:would_refuse, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert :ok = deny.()
      assert_receive {:would_refuse, %{surface: :test, visibility: :capability_gated}}, 500
    end

    test "enforce: would-deny actually denies", %{deny: deny} do
      Application.put_env(:commonplace, :local_read_gate, :enforce)
      assert {:error, :read_denied} = deny.()
    end

    test "enforce: a PUBLIC target short-circuits to :ok (no-regression)" do
      Application.put_env(:commonplace, :local_read_gate, :enforce)
      assert :ok = Read.gate("stranger", UUID.uuid4(), surface: :test, visibility: :public)
    end
  end
end

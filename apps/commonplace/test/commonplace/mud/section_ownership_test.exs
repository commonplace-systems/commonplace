defmodule Commonplace.MUD.SectionOwnershipTest do
  @moduledoc """
  CX-qat5.4 Part A acceptance test — the M2 demo bar: X owns a section
  (a set of room docs) via a capability cert and edits it; Y (a
  registered, signed player with NO cert) is DENIED at the same
  verifier that gates federation imports; X delegates an attenuated
  cert to Z and Z edits within its narrowed scope. See
  docs/plans/2026-07-06-qat5.4-section-ownership-spec.md §2.2 for the
  seven numbered beats this test pins.

  Setup mirrors `Commonplace.Store.LocalWriteGateTest` (named store
  trio + strict trust config + `:enforce` gate) and
  `Commonplace.Chat.SessionGateSmokeTest` (strict-mode
  player-vs-anonymous pattern, `Commonplace.Invites`-style player
  registration). The fence-rider pin (beat 6) mirrors
  `Commonplace.Trust.ExecuteCapabilityNamedStoreTest` — the named-store
  capability path CX-ziye fixed.

  ## Interim honesty on "revocation" (beat 5)

  Per the spec's scope split (§1), true revocation records were NOT part
  of THIS build (design-first, its own bead — CX-bepn, since landed).
  Beat 5 exercises the INTERIM mechanism that shipped alongside this
  test: a short `not_after` caveat window that expires and denies
  `:expired` — real, enforced, already in `Commonplace.Trust.VerifyChain`.

  ## True revocation (beat 5b, CX-bepn)

  Beat 5b is the TRUE-revocation sibling beat qat5.4's expiry beat
  promised (design doc §8 step 7): X revokes Z's mid-session cert (X is
  the cert's own issuer — path-issuer authority, §2) and Z's very next
  edit denies `{:trust_rejected, :revoked}` — no caveat window, no
  waiting for expiry, immediate and terminal.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Chat.{Actions, Messages}
  alias Commonplace.Crypto.{AgentKeys, Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.MUD.Sections
  alias Commonplace.Presence.Identity
  alias Commonplace.Store.{CommitStore, CommitStoreClient, SecretStore}
  alias Commonplace.Tree.Schema
  alias Commonplace.Trust

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_section_ownership_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    name = :"so_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"so_sup_#{n}",
       commit_store_name: name,
       trust_side_store_name: :"so_tss_#{n}",
       pending_imports_name: :"so_pi_#{n}"}
    )

    secrets_dir =
      Path.join(System.tmp_dir!(), "cp_section_secrets_#{:rand.uniform(1_000_000_000)}")

    File.mkdir_p!(secrets_dir)
    secrets_name = :"so_secrets_#{n}"
    {:ok, secrets_pid} = SecretStore.start_link(data_dir: secrets_dir, name: secrets_name)

    old_trust = Application.get_env(:commonplace, :trust)
    old_knob = Application.get_env(:commonplace, :local_write_gate)

    on_exit(fn ->
      case old_trust do
        nil -> Application.delete_env(:commonplace, :trust)
        v -> Application.put_env(:commonplace, :trust, v)
      end

      case old_knob do
        nil -> Application.delete_env(:commonplace, :local_write_gate)
        v -> Application.put_env(:commonplace, :local_write_gate, v)
      end

      if Process.alive?(secrets_pid),
        do:
          (try do
             GenServer.stop(secrets_pid)
           catch
             (:exit, _ -> :ok)
           end)

      File.rm_rf!(dir)
      File.rm_rf!(secrets_dir)
    end)

    # --- root: the locally-pinned trust anchor (unattenuated root cert
    # issuer). Not a registered player — anchors are local config, never
    # a synced identity doc (per Trust's moduledoc).
    {root_pub, root_priv} = Signing.generate_keypair()

    root_ctx = %SigningContext{
      identity_uuid: "root",
      private_key: root_priv,
      public_key: root_pub
    }

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{"root" => Signing.encode_key(root_pub)}
    })

    Application.put_env(:commonplace, :local_write_gate, :enforce)

    # --- identity root doc (for register_player's tree) + the two
    # section room docs, both created by ROOT (a trusted signer) so
    # their genesis lands cleanly under strict + enforce.
    identity_root_uuid = UUID.uuid4()
    root_schema_update = Yelixer.Encoding.encode_update(Schema.new_schema())

    CommitStore.create_commit(name, identity_root_uuid, root_schema_update, nil, %{},
      signing_context: root_ctx
    )

    room1_uuid = UUID.uuid4()
    room2_uuid = UUID.uuid4()

    CommitStore.create_commit(name, room1_uuid, room_update("room-1, empty"), nil, %{},
      signing_context: root_ctx
    )

    CommitStore.create_commit(name, room2_uuid, room_update("room-2, empty"), nil, %{},
      signing_context: root_ctx
    )

    messages_uuid = UUID.uuid4()

    CommitStore.create_commit(
      name,
      messages_uuid,
      Yelixer.Encoding.encode_update(Messages.new()),
      nil,
      %{},
      signing_context: root_ctx
    )

    # --- three registered player identities: X, Y, Z.
    {:ok, x_uuid, x_pub} =
      Identity.register_player("x", identity_root_uuid, name,
        signing_context: root_ctx,
        secret_store: secrets_name
      )

    {:ok, y_uuid, y_pub} =
      Identity.register_player("y", identity_root_uuid, name,
        signing_context: root_ctx,
        secret_store: secrets_name
      )

    {:ok, z_uuid, z_pub} =
      Identity.register_player("z", identity_root_uuid, name,
        signing_context: root_ctx,
        secret_store: secrets_name
      )

    {:ok, x_ctx} = AgentKeys.signing_context_for(x_uuid, secrets_name)
    {:ok, y_ctx} = AgentKeys.signing_context_for(y_uuid, secrets_name)
    {:ok, z_ctx} = AgentKeys.signing_context_for(z_uuid, secrets_name)

    %{
      store: name,
      root_ctx: root_ctx,
      room1: room1_uuid,
      room2: room2_uuid,
      messages_uuid: messages_uuid,
      x: %{uuid: x_uuid, pub: x_pub, ctx: x_ctx},
      y: %{uuid: y_uuid, pub: y_pub, ctx: y_ctx},
      z: %{uuid: z_uuid, pub: z_pub, ctx: z_ctx}
    }
  end

  defp room_update(body) do
    doc = Yelixer.Doc.new() |> ContentType.create(:text, "__room.json")
    doc = ContentType.insert_text(doc, 0, body)
    Yelixer.Encoding.encode_update(doc)
  end

  test "the M2 demo bar: own/edit, deny, delegate, attenuate, expire, write!=execute, cross-surface",
       %{
         store: store,
         root_ctx: root_ctx,
         room1: room1,
         room2: room2,
         messages_uuid: messages_uuid,
         x: x,
         y: y,
         z: z
       } do
    # ── Beat 2: root issues X a [:write, :delegate] cert over the
    #    section (room1, room2) → X's signed write to room1 LANDS.
    #    (`:delegate` so X can attenuate onward to Z in beat 4 — the
    #    write authority itself is still write-only, never :execute.)
    assert {:ok, x_cap} =
             Sections.issue_section(root_ctx, {x.uuid, x.pub}, [room1, room2],
               store: store,
               verbs: [:write, :delegate]
             )

    assert x_commit =
             CommitStoreClient.create_chained_commit(
               store,
               room1,
               room_update("room-1, decorated by X"),
               %{kind: :regular, capability_proof: x_cap.id},
               signing_context: x.ctx
             )

    assert %Commonplace.Store.Commit{} = x_commit
    assert {:ok, _} = CommitStore.get_commit(store, x_commit.id)

    # ── Beat 6 (checked here, before beat 5's EXPIRING cert lands any
    #    further commits on room1 — `authorized_to_execute?`'s walk
    #    re-validates every contributor's caveat window against "now" at
    #    CHECK time, so an expired short-lived cert elsewhere in room1's
    #    history would otherwise shadow this pin's actual claim under a
    #    different reason). Fence rider: X's [:write] section cert does
    #    NOT authorize :execute on a doc in the section, end-to-end via
    #    the Gate-B walk on this NAMED store (CX-ziye fixed the crash
    #    that used to make this untestable off the default store).
    cfg = Trust.config()

    assert {:error, {:untrusted_contributor, _, :capability_insufficient}} =
             Trust.authorized_to_execute?(store, room1, cfg)

    # ── Beat 3: Y (registered, signed, NO cert) writes room1 → DENIED,
    #    red event fires, nothing persisted beyond X's commit.
    Commonplace.Dataflow.PubSub.subscribe_red(room1)

    assert {:error, {:trust_rejected, {:untrusted_signer, y_uuid}}} =
             CommitStoreClient.create_chained_commit(
               store,
               room1,
               room_update("room-1, defaced by Y"),
               %{},
               signing_context: y.ctx
             )

    assert y_uuid == y.uuid

    assert_receive {"red:" <> ^room1, {:trust, :local_write_denied, meta}}, 500
    assert meta.doc_uuid == room1
    assert meta.reason == {:untrusted_signer, y.uuid}

    # Nothing persisted: room1's head is still X's commit.
    assert {:ok, head} = CommitStore.latest_commit(store, room1)
    assert head.id == x_commit.id

    # ── Beat 4: X delegates room1-only to Z → Z's write to room1 LANDS;
    #    Z's write to room2 (out of the attenuated scope) is DENIED.
    assert {:ok, z_cap} =
             Sections.delegate_section(x.ctx, {z.uuid, z.pub}, [room1],
               store: store,
               parent: x_cap,
               verbs: [:write]
             )

    assert Commonplace.Trust.Capability.attenuates?(z_cap.claim, x_cap.claim)

    assert z_commit =
             CommitStoreClient.create_chained_commit(
               store,
               room1,
               room_update("room-1, tidied by Z"),
               %{kind: :regular, capability_proof: z_cap.id},
               signing_context: z.ctx
             )

    assert %Commonplace.Store.Commit{} = z_commit
    assert {:ok, _} = CommitStore.get_commit(store, z_commit.id)

    assert {:error, {:trust_rejected, :capability_insufficient}} =
             CommitStoreClient.create_chained_commit(
               store,
               room2,
               room_update("room-2, overreached by Z"),
               %{kind: :regular, capability_proof: z_cap.id},
               signing_context: z.ctx
             )

    # room2 untouched by Z's denied write.
    assert {:ok, room2_head} = CommitStore.latest_commit(store, room2)
    refute room2_head.metadata[:capability_proof] == z_cap.id

    # ── Beat 5: a delegation with a 1-second `not_after` → after expiry
    #    Z is DENIED `:expired` (the interim revocation beat — real
    #    time-caveat enforcement, not true revocation; see moduledoc).
    assert {:ok, short_cap} =
             Sections.delegate_section(x.ctx, {z.uuid, z.pub}, [room1],
               store: store,
               parent: x_cap,
               verbs: [:write],
               ttl_seconds: 1
             )

    # Immediately after mint the cert is still valid.
    assert %Commonplace.Store.Commit{} =
             CommitStoreClient.create_chained_commit(
               store,
               room1,
               room_update("room-1, quick edit by Z before expiry"),
               %{kind: :regular, capability_proof: short_cap.id},
               signing_context: z.ctx
             )

    Process.sleep(1_500)

    assert {:error, {:trust_rejected, :expired}} =
             CommitStoreClient.create_chained_commit(
               store,
               room1,
               room_update("room-1, edit by Z after expiry"),
               %{kind: :regular, capability_proof: short_cap.id},
               signing_context: z.ctx
             )

    # ── Beat 5b (CX-bepn): TRUE revocation — X (the cert's own issuer,
    #    §2 path-issuer authority) revokes Z's ORIGINAL (unbounded) cert
    #    mid-session. Z's cert is still cryptographically well-formed and
    #    was granting fine a moment ago (beat 4) — but the very next edit
    #    now denies `:revoked`, terminal, no caveat window involved.
    assert {:ok, revocation} = Commonplace.Trust.Capability.revoke(x.ctx, z_cap.id)
    assert :ok = CommitStoreClient.store_revocation(store, revocation)

    assert {:error, {:trust_rejected, :revoked}} =
             CommitStoreClient.create_chained_commit(
               store,
               room1,
               room_update("room-1, edit by Z after TRUE revocation"),
               %{kind: :regular, capability_proof: z_cap.id},
               signing_context: z.ctx
             )

    # ── Beat 7: cross-surface — the SAME denied write (Y, no cert) via
    #    the browser action path (`Chat.Actions.post_message`, the same
    #    seam `ChatRoomLive`/`SessionGateSmokeTest` dispatch through)
    #    surfaces the error tuple, not a crash.
    assert {:error, {:trust_rejected, {:untrusted_signer, y_uuid2}}} =
             Actions.post_message(messages_uuid, "hi from an uncapped Y",
               room: "forest-path",
               signer_id: Signing.signer_id(y.uuid, y.pub),
               author_path: "y.usr",
               signing_context: y.ctx,
               store: store
             )

    assert y_uuid2 == y.uuid
  end
end

defmodule Commonplace.MUD.HumanWebPlayTest do
  @moduledoc """
  The human-web-play chunk (CX-zyee / CX-jicn) — a logged-in HUMAN
  playing the browser MUD under `local_write_gate: :enforce`.

  These drive a `PlayerSession` provisioned EXACTLY the way
  `CommonplaceWebWeb.MudLive.mount/3` provisions a browser player:

    * a per-player Ed25519 signing identity minted in node-local
      `SecretStore` custody (`Identity.register_player/4` →
      `AgentKeys.ensure/2` — the same custody `Invites.mint/4` lands and
      `CommonplaceWebWeb.SessionIdentity.resolve/1` re-reads on each
      mount), and
    * full citizenship via the SHARED `Citizenship.ensure/5` seam
      (presence-starter cert + a node-signed `players/<name>/` home ROOM
      the player OWNS + a `{:docs}` home-zone write cert).

  Mirrors `PlayerSessionIdentityTest` / `CitizenshipTest`'s strict+enforce
  scaffold (node auto-trusted, unsigned commits rejected, capability
  checks enforced) so every claim below is proven under the SAME gate the
  live :5199 serve runs.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{AgentKeys, NodeIdentity, Signing, SigningContext}
  alias Commonplace.MUD.{Citizenship, PlayerSession, Schemas}
  alias Commonplace.Presence.Identity
  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_humanweb_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"humanweb_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"humanweb_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"humanweb_tss_#{n}",
       pending_imports_name: :"humanweb_pi_#{n}"}
    )

    secrets_dir = Path.join(System.tmp_dir!(), "cp_humanweb_secrets_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(secrets_dir)
    secrets = :"humanweb_secrets_#{n}"
    {:ok, secrets_pid} = SecretStore.start_link(data_dir: secrets_dir, name: secrets)

    # CX-6hxa: save/restore under the REAL app-env key names.
    old_data_dir = Application.get_env(:commonplace, :data_dir)
    old_trust = Application.get_env(:commonplace, :trust)
    old_knob = Application.get_env(:commonplace, :local_write_gate)

    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    on_exit(fn ->
      restore(:data_dir, old_data_dir)
      restore(:trust, old_trust)
      restore(:local_write_gate, old_knob)
      if Process.alive?(secrets_pid), do: GenServer.stop(secrets_pid)
      File.rm_rf!(dir)
      File.rm_rf!(secrets_dir)
    end)

    {:ok, node_ctx} = NodeIdentity.signing_context()

    # workspace root (identity registry) + a distinct mud world root.
    ws_root = UUID.uuid4()
    genesis(store, ws_root, node_ctx)
    mud_root = UUID.uuid4()
    genesis(store, mud_root, node_ctx)

    %{store: store, secrets: secrets, node_ctx: node_ctx, ws_root: ws_root, mud_root: mud_root}
  end

  defp restore(key, nil), do: Application.delete_env(:commonplace, key)
  defp restore(key, v), do: Application.put_env(:commonplace, key, v)

  defp genesis(store, uuid, ctx) do
    CommitStore.create_commit(store, uuid, Yelixer.Encoding.encode_update(Schema.new_schema()), nil, %{}, signing_context: ctx)
    uuid
  end

  # Provisions a browser-style signed citizen and starts a buffered
  # PlayerSession for them. Returns %{pid, id_uuid, pub, signer_id, sctx,
  # cert_cids, home}.
  defp provision_and_start(name, ctx) do
    {:ok, id_uuid, pub} =
      Identity.register_player(name, ctx.ws_root, ctx.store,
        signing_context: ctx.node_ctx,
        secret_store: ctx.secrets
      )

    {:ok, sctx} = AgentKeys.signing_context(id_uuid, ctx.secrets)
    signer_id = Signing.signer_id(id_uuid, pub)

    {:ok, %{cert_cids: cert_cids, home_room_uuid: home}} =
      Citizenship.ensure(id_uuid, pub, name, ctx.mud_root, ctx.store)

    {:ok, pid} =
      PlayerSession.start_link(
        player_name: name,
        root_uuid: ctx.mud_root,
        store: ctx.store,
        buffered: true,
        signing_context: sctx,
        signer_id: signer_id,
        cert_cids: cert_cids,
        spawn_room_uuid: home
      )

    %{pid: pid, id_uuid: id_uuid, pub: pub, signer_id: signer_id, sctx: sctx, cert_cids: cert_cids, home: home}
  end

  defp home_meta_uuid(store, home) do
    {:ok, schema} = Schemas.load_dir_schema(home, store)
    {:ok, entry} = Schema.get_entry(schema, Schemas.room_filename())
    entry.node_id
  end

  # ---- CX-jicn.1 : per-player web signing identity ----

  test "H1: a provisioned browser session is SIGNED (real keypair, non-nil signer_id) and its OWN home write LANDS under enforce",
       ctx do
    p = provision_and_start("frodo", ctx)

    # The session carries a REAL signing identity — a private key in
    # custody and a non-nil signer_id — NOT an unsigned/read-only context.
    assert %SigningContext{private_key: priv, public_key: pubk} = p.sctx
    assert is_binary(priv) and byte_size(priv) > 0
    assert is_binary(pubk) and byte_size(pubk) > 0
    assert is_binary(p.signer_id)

    _greet = PlayerSession.drain_buffer(p.pid)

    home_meta = home_meta_uuid(ctx.store, p.home)
    {:ok, before} = CommitStore.latest_commit(ctx.store, home_meta)

    :ok = PlayerSession.input_sync(p.pid, "@name here Frodos-Hole")
    out = Enum.join(PlayerSession.drain_buffer(p.pid), "\n")

    # The write is signed AND authorized by the citizenship home-zone cert.
    assert out =~ "Updated room name."

    {:ok, aft} = CommitStore.latest_commit(ctx.store, home_meta)
    assert aft.id != before.id, "the home-room write must LAND under enforce"
    assert aft.signer_id == p.signer_id, "the landed commit is signed as the player"

    PlayerSession.stop(p.pid)
  end

  test "H3: a signed citizen is DENIED building in a room they do NOT own (signing != authority)", ctx do
    # CX-cl65 reframe: post-A3, `@dig` builds under the invoker's OWN home
    # (which they're authorized for — that's the M2 feature, proven by H1's
    # in-home `@name here` landing), and the exit-edge write lands on the
    # CURRENT room. So a genuine beyond-zone test must put the player in a room
    # they do NOT hold a cert for. A second citizen's home is exactly that.
    # (This test previously stood the player in their own home and asserted
    # @dig was refused — it was green only because the CX-cl65 zone-drop bug
    # wrongly denied the legitimate in-home exit-write; that premise is obsolete.)
    landlord = provision_and_start("landlord", ctx)
    PlayerSession.stop(landlord.pid)
    others_home = landlord.home
    others_meta = home_meta_uuid(ctx.store, others_home)

    # Start frodo STANDING IN the landlord's home — a room outside frodo's zone.
    {:ok, id_uuid, pub} =
      Identity.register_player("frodo", ctx.ws_root, ctx.store,
        signing_context: ctx.node_ctx,
        secret_store: ctx.secrets
      )

    {:ok, sctx} = AgentKeys.signing_context(id_uuid, ctx.secrets)
    signer_id = Signing.signer_id(id_uuid, pub)
    {:ok, %{cert_cids: cert_cids}} = Citizenship.ensure(id_uuid, pub, "frodo", ctx.mud_root, ctx.store)

    {:ok, pid} =
      PlayerSession.start_link(
        player_name: "frodo",
        root_uuid: ctx.mud_root,
        store: ctx.store,
        buffered: true,
        signing_context: sctx,
        signer_id: signer_id,
        cert_cids: cert_cids,
        spawn_room_uuid: others_home
      )

    _greet = PlayerSession.drain_buffer(pid)
    {:ok, others_before} = CommitStore.latest_commit(ctx.store, others_meta)

    # The exit-edge write targets the LANDLORD's home meta — a doc frodo holds
    # no cert for. Signing gives identity, not authority: the exit-write is
    # refused (the new-room genesis under frodo's OWN home may land, orphaned —
    # the documented partial-write behavior — but the un-owned room never moves).
    :ok = PlayerSession.input_sync(pid, "@dig north Frodos-Folly")
    out = Enum.join(PlayerSession.drain_buffer(pid), "\n")

    assert out =~ "permission", "a write beyond the player's zone must be refused (H3)"

    {:ok, others_after} = CommitStore.latest_commit(ctx.store, others_meta)
    assert others_after.id == others_before.id, "the un-owned room's meta must NOT move (beyond-zone write denied)"

    PlayerSession.stop(pid)
  end

  # ---- CX-zyee : the greet renders as the session-open turn, in order ----

  test "zyee: greet lands Welcome + room in the buffer as the OPEN turn; a later look returns its OWN room, not the stale banner",
       ctx do
    p = provision_and_start("sam", ctx)

    # This drain models MudLive's `:enter` (mailbox-ordered AFTER the
    # session's own `:greet`). It must capture BOTH the Welcome banner and
    # the spawn-room render — synchronously, no async-cast race.
    open_turn = Enum.join(PlayerSession.drain_buffer(p.pid), "\n")
    assert open_turn =~ "Welcome, sam."
    assert open_turn =~ "sam's Home", "the greet's room render must be part of the OPEN turn"

    # A subsequent `look` returns its OWN room render — the stale Welcome
    # banner must NOT bleed into it (the CX-zyee symptom).
    :ok = PlayerSession.input_sync(p.pid, "look")
    look_turn = Enum.join(PlayerSession.drain_buffer(p.pid), "\n")
    assert look_turn =~ "sam's Home"
    refute look_turn =~ "Welcome", "the Welcome banner must not bleed into a later command's output"

    PlayerSession.stop(p.pid)
  end

  # ---- CX-jicn.2 : raw trust tuples never reach the pane ----

  test "jicn.2: a raw {:trust, :local_write_denied, ...} red event renders to NOTHING — no tuple, no inspect", ctx do
    p = provision_and_start("pippin", ctx)
    _greet = PlayerSession.drain_buffer(p.pid)

    # Exactly the payload CommitStore.broadcast_red/2 fans out on an
    # enforce denial, delivered on a `red:` topic the session subscribes to.
    send(
      p.pid,
      {"red:#{p.home}",
       {:trust, :local_write_denied, %{doc_uuid: p.home, signer_id: p.signer_id, reason: :capability_insufficient}}}
    )

    # And the unsigned-housekeeping flavor, too.
    send(
      p.pid,
      {"red:#{p.home}",
       {:trust, :local_write_denied, %{doc_uuid: p.home, signer_id: nil, reason: :unsigned}}}
    )

    out = Enum.join(PlayerSession.drain_buffer(p.pid), "\n")

    refute out =~ ":trust"
    refute out =~ "local_write_denied"
    refute out =~ "capability_insufficient"
    refute out =~ "(event:", "an internal trust tuple must never be inspect/1-ed to the player"

    PlayerSession.stop(p.pid)
  end

end

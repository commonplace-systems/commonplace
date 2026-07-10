defmodule Commonplace.Presence.SigningTest do
  @moduledoc """
  CX-i9w9 (presence-signing, Model A) — under `local_write_gate: :enforce`,
  presence writes must be SIGNED to land: a player signs their OWN presence
  (create/heartbeat/remove) and presents the citizenship-minted
  `{:presence, id}` cert, which the CX-0a9a carve authorizes (bound_identity
  == signer) — INCLUDING the room-dir enter/leave add/remove. Unsigned writes
  are `{:trust_rejected, :unsigned}` (the ghost/frozen-timestamp cause). The
  reaper's abandoned-ghost GC is NODE-signed (it can't hold the departed
  player's key).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Presence
  alias Commonplace.Presence.Reaper
  alias Commonplace.Trust.Capability
  alias Commonplace.Crypto.{Signing, SigningContext, NodeIdentity}
  alias Commonplace.MUD.Schemas
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{Schema, DocBuilder}
  alias Commonplace.Document.ContentType

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_pres_sign_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"pres_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"pres_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"pres_tss_#{n}",
       pending_imports_name: :"pres_pi_#{n}"}
    )

    old = %{
      data_dir: Application.get_env(:commonplace, :data_dir),
      trust: Application.get_env(:commonplace, :trust),
      gate: Application.get_env(:commonplace, :local_write_gate)
    }

    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    on_exit(fn ->
      for {k, v} <- old do
        key = %{data_dir: :data_dir, trust: :trust, gate: :local_write_gate}[k]
        if is_nil(v), do: Application.delete_env(:commonplace, key), else: Application.put_env(:commonplace, key, v)
      end

      File.rm_rf!(dir)
    end)

    {:ok, node_ctx} = NodeIdentity.signing_context()

    # a node-owned room dir (like a curated MUD room)
    {:ok, room} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Schemas.Room{name: "Room", description: "a room"}),
        store,
        signing_context: node_ctx
      )

    %{store: store, node_ctx: node_ctx, room: room}
  end

  # A fresh player identity + its node-issued {:presence, id} [:write] cert.
  defp player_with_presence_cert(store, node_ctx) do
    {pub, priv} = Signing.generate_keypair()
    pid = UUID.uuid4()
    ctx = %SigningContext{identity_uuid: pid, public_key: pub, private_key: priv}

    {:ok, cap} =
      Capability.issue(node_ctx, {pid, pub}, %{verbs: [:write], scope: {:presence, pid}, caveats: %{}}, nil, store: store)

    :ok = CommitStoreClient.store_capability(store, cap)
    %{id: pid, ctx: ctx, creds: [signing_context: ctx, cert_cids: [cap.id]]}
  end

  defp usr_entries(room, store) do
    {:ok, sch} = Schemas.load_dir_schema(room, store)
    sch |> Schema.entries() |> Map.keys() |> Enum.filter(&String.ends_with?(&1, ".usr"))
  end

  defp heartbeat_of(puuid, store) do
    {:ok, doc} = DocBuilder.reconstruct_doc(store, puuid)
    case ContentType.get_content(doc) do
      %{"heartbeat" => hb} -> hb
      _ -> nil
    end
  end

  test "UNSIGNED presence create is refused under enforce (the ghost cause)", %{store: store, room: room} do
    # create writes the presence doc AND the room-dir entry; unsigned → the
    # dir entry never lands, so no .usr appears.
    Presence.create("anon", :usr, room, store)
    assert usr_entries(room, store) == []
  end

  test "SIGNED player presence: create + heartbeat + remove all land via the carve", %{
    store: store,
    node_ctx: node_ctx,
    room: room
  } do
    p = player_with_presence_cert(store, node_ctx)

    # CREATE (player-signed + presence cert) → .usr lands in the node-owned dir
    {:ok, puuid} = Presence.create("player-#{p.id |> String.slice(0, 6)}", :usr, room, store, p.creds)
    assert length(usr_entries(room, store)) == 1
    hb0 = heartbeat_of(puuid, store)
    assert is_binary(hb0)

    # HEARTBEAT (player-signed) → lands + advances the timestamp
    Process.sleep(5)
    assert %Commonplace.Store.Commit{} = Presence.heartbeat(puuid, store, p.creds)
    hb1 = heartbeat_of(puuid, store)
    assert hb1 != hb0

    # REMOVE own presence (player-signed) → the .usr entry retracts (no ghost)
    fname = hd(usr_entries(room, store))
    assert %Commonplace.Store.Commit{} = Presence.remove(fname, room, store, p.creds)
    assert usr_entries(room, store) == []
  end

  test "UNSIGNED heartbeat is refused; the frozen-timestamp symptom", %{store: store, node_ctx: node_ctx, room: room} do
    p = player_with_presence_cert(store, node_ctx)
    {:ok, puuid} = Presence.create("frz", :usr, room, store, p.creds)
    hb0 = heartbeat_of(puuid, store)

    assert {:error, {:trust_rejected, :unsigned}} = Presence.heartbeat(puuid, store)
    assert heartbeat_of(puuid, store) == hb0
  end

  test "reaper stays a DELIBERATE no-op under enforce (unsigned) — must not reap the frozen-heartbeat living", %{
    store: store,
    node_ctx: node_ctx,
    room: room
  } do
    # CX-i9w9 safety: node-signing the reaper would make it retract, but
    # `find_stale` keys off the heartbeat, and MUD presences never heartbeat
    # (frozen at create) → a signed reaper would reap LIVE players after the
    # stale threshold. So the reaper stays unsigned (denied under enforce = a
    # no-op) until heartbeating lands. This test PINS that safety: the entry
    # must SURVIVE a reap, even at stale_threshold 0 (everything "stale").
    p = player_with_presence_cert(store, node_ctx)
    {:ok, _puuid} = Presence.create("ghost", :usr, room, store, p.creds)
    assert length(usr_entries(room, store)) == 1

    Reaper.reap(room, store, 0)
    assert length(usr_entries(room, store)) == 1, "reaper must be a no-op under enforce (would reap living)"
  end
end

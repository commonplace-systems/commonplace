defmodule Commonplace.Bots.CitizenTest do
  @moduledoc """
  Camillo slice C2 — CITIZEN WITH A HOUSE.

  `Commonplace.Bots.Citizen.provision/4` turns a native-agent bot into a MUD
  full-citizen with a seeded foyer, built through the SAME player-build cores
  (`Commonplace.MUD.Build`) a human's `@dig`/`@create` drives, signed by the
  bot's OWN key. These tests run under `local_write_gate: :enforce` + strict
  trust (unsigned rejected) so every assertion proves the bot's writes are
  genuinely bot-signed and land under the strict gate — not "would have been fine
  permissively".
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.Citizen
  alias Commonplace.Bots.Identity, as: BotIdentity
  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.MUD.{Schemas, World}
  alias Commonplace.MUD.Schemas.Room
  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    n = :rand.uniform(1_000_000_000)
    dir = Path.join(System.tmp_dir!(), "cp_bots_citizen_#{n}")
    File.mkdir_p!(dir)
    store = :"citizen_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"citizen_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"citizen_tss_#{n}",
       pending_imports_name: :"citizen_pi_#{n}"}
    )

    # Isolate NodeIdentity's keypair to this test's tmp dir (deterministic node
    # identity + auto-trust, no collision with other suites).
    old_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    old_trust = Application.get_env(:commonplace, :trust)
    old_knob = Application.get_env(:commonplace, :local_write_gate)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    secrets_dir = Path.join(System.tmp_dir!(), "cp_bots_citizen_secrets_#{n}")
    File.mkdir_p!(secrets_dir)
    secrets = :"citizen_secrets_#{n}"
    {:ok, secrets_pid} = SecretStore.start_link(data_dir: secrets_dir, name: secrets)

    on_exit(fn ->
      Application.put_env(:commonplace, :data_dir, old_data_dir || "tmp/test_data")

      case old_trust do
        nil -> Application.delete_env(:commonplace, :trust)
        v -> Application.put_env(:commonplace, :trust, v)
      end

      case old_knob do
        nil -> Application.delete_env(:commonplace, :local_write_gate)
        v -> Application.put_env(:commonplace, :local_write_gate, v)
      end

      if Process.alive?(secrets_pid) do
        try do
          GenServer.stop(secrets_pid)
        catch
          :exit, _ -> :ok
        end
      end

      File.rm_rf!(dir)
      File.rm_rf!(secrets_dir)
    end)

    {:ok, node_ctx} = NodeIdentity.signing_context()

    # The MUD root — a schema doc, node-signed (so it lands under enforce).
    mud_root = UUID.uuid4()

    assert %Commonplace.Store.Commit{} =
             CommitStore.create_commit(
               store,
               mud_root,
               Encoding.encode_update(Schema.new_schema()),
               nil,
               %{},
               signing_context: node_ctx
             )

    %{store: store, mud_root: mud_root, secrets: secrets, node_ctx: node_ctx}
  end

  defp provision(name, ctx) do
    Citizen.provision(name, ctx.mud_root, ctx.store, secret_store: ctx.secrets)
  end

  # The load-bearing guard: the principal the C1 chat-Worker entry point resolves
  # (`BotIdentity.resolve_signing_context/4` under the MUD root) is the SAME
  # identity_uuid `provision/4` builds the citizen from. If a surface resolved
  # under a different root, it would mint a DIFFERENT principal and this pin
  # would break.
  test "cross-surface identity pin: chat-Worker resolve == provision identity", ctx do
    assert {:ok, %SigningContext{} = sc} =
             BotIdentity.resolve_signing_context("camillo", ctx.mud_root, ctx.store,
               secret_store: ctx.secrets
             )

    assert {:ok, %{identity_uuid: provisioned_id}} = provision("camillo", ctx)

    assert sc.identity_uuid == provisioned_id
  end

  test "provision creates home -> foyer -> study reachable by exits, map in foyer", ctx do
    assert {:ok, r} = provision("camillo", ctx)

    # Walk the exit edges: home --north--> foyer --north--> study, reciprocals.
    assert {:ok, %Room{exits: home_exits}} = World.get_room(r.home_room_uuid, ctx.store)
    assert home_exits["north"] == r.foyer_uuid

    assert {:ok, %Room{exits: foyer_exits}} = World.get_room(r.foyer_uuid, ctx.store)
    assert foyer_exits["north"] == r.study_uuid
    assert foyer_exits["south"] == r.home_room_uuid

    assert {:ok, %Room{exits: study_exits}} = World.get_room(r.study_uuid, ctx.store)
    assert study_exits["south"] == r.foyer_uuid

    # The map item is in the foyer, an object entry.
    assert {:ok, entry} = World.find_entry_by_name(r.foyer_uuid, "map", ctx.store)
    assert String.ends_with?(entry.name, ".obj")

    # The bot's presence stands in the foyer.
    assert {:ok, foyer_schema} = Schemas.load_dir_schema(r.foyer_uuid, ctx.store)
    assert {:ok, _} = Schema.get_entry(foyer_schema, "camillo.usr")
  end

  test "seeded content is bot-SIGNED (not node) and zone-inherited from home", ctx do
    assert {:ok, r} = provision("camillo", ctx)

    {:ok, sc} =
      BotIdentity.resolve_signing_context("camillo", ctx.mud_root, ctx.store,
        secret_store: ctx.secrets
      )

    bot_signer_id = Signing.signer_id(sc.identity_uuid, sc.public_key)

    node_signer_id =
      Signing.signer_id(ctx.node_ctx.identity_uuid, ctx.node_ctx.public_key)

    refute bot_signer_id == node_signer_id

    # The bot's build write — the home's north->foyer exit edge — is the LATEST
    # commit on home's room-meta doc, and it is BOT-signed. (The child zone-STAMP
    # genesis is node-signed by construction, CX-4u03 split authority; the exit
    # edge + entry-add are the bot's own creds.)
    home_meta = room_meta_uuid(r.home_room_uuid, ctx.store)
    assert {:ok, home_commit} = CommitStore.latest_commit(ctx.store, home_meta)
    assert home_commit.signer_id == bot_signer_id

    # The foyer's north->study exit edge is likewise bot-signed.
    foyer_meta = room_meta_uuid(r.foyer_uuid, ctx.store)
    assert {:ok, foyer_commit} = CommitStore.latest_commit(ctx.store, foyer_meta)
    assert foyer_commit.signer_id == bot_signer_id

    # Zone-inheritance: home is a self-rooted zone; every dug room / created item
    # under it inherits zone == home (via ChildMutation.create_zoned_child).
    assert Commonplace.Trust.doc_zone(r.home_room_uuid, ctx.store) == r.home_room_uuid
    assert Commonplace.Trust.doc_zone(r.foyer_uuid, ctx.store) == r.home_room_uuid
    assert Commonplace.Trust.doc_zone(r.study_uuid, ctx.store) == r.home_room_uuid

    {:ok, map_entry} = World.find_entry_by_name(r.foyer_uuid, "map", ctx.store)
    assert Commonplace.Trust.doc_zone(map_entry.node_id, ctx.store) == r.home_room_uuid
  end

  test "idempotent: provision twice -> same identity, no duplicate rooms", ctx do
    assert {:ok, r1} = provision("camillo", ctx)
    assert {:ok, r2} = provision("camillo", ctx)

    assert r1.identity_uuid == r2.identity_uuid
    assert r1.home_room_uuid == r2.home_room_uuid
    assert r1.foyer_uuid == r2.foyer_uuid
    assert r1.study_uuid == r2.study_uuid

    # No duplicate rooms under home: exactly the two rooms the seed dug (foyer +
    # study) live as .json room-meta-bearing dir entries under home, plus the
    # home's own __room.json + inventory. Assert the two dug rooms are unique.
    {:ok, home_schema} = Schemas.load_dir_schema(r1.home_room_uuid, ctx.store)

    room_children =
      home_schema
      |> Schema.list_entries()
      |> Enum.filter(fn e -> e.node_id in [r1.foyer_uuid, r1.study_uuid] end)
      |> Enum.map(& &1.node_id)
      |> Enum.uniq()

    assert Enum.sort(room_children) == Enum.sort([r1.foyer_uuid, r1.study_uuid])

    # No duplicate map in the foyer.
    {:ok, foyer_schema} = Schemas.load_dir_schema(r1.foyer_uuid, ctx.store)

    map_entries =
      foyer_schema
      |> Schema.list_entries()
      |> Enum.filter(fn e -> String.contains?(e.name, "map") end)

    assert length(map_entries) == 1
  end

  defp room_meta_uuid(dir_uuid, store) do
    {:ok, schema} = Schemas.load_dir_schema(dir_uuid, store)
    {:ok, entry} = Schema.get_entry(schema, Schemas.room_filename())
    entry.node_id
  end
end

defmodule Commonplace.Bots.ForkMinterTest do
  @moduledoc """
  CX-iwf5 (cp-plan ruling #8965) — the FORK-MINTER fix, two halves:

    (a) `Commonplace.Bots.Citizen.provision/4`'s presence step searches
        EVERYWHERE (`World.find_presence/3`, root-relative) before minting
        — not just the foyer — so re-provisioning a bot standing anywhere
        else (walked, or externally moved) is a NO-OP, not a fork.
    (b) `World.find_presence/3` itself: when the SAME filename is found in
        MORE than one room, it REFUSES to pick one
        (`{:error, :ambiguous_presence}` + `Logger.warning`) rather than
        silently arbitrating by tree-walk order.

  Pins authored FROM THE SPEC (lesson #8): (1) provision-while-standing-
  in-a-non-foyer-room is a NO-OP — enumeration across all home rooms
  finds exactly one `.usr`, RED against the pre-fix code (verified below,
  restored after); (2) duplicates → `find_presence` refuses AND logs
  (constructed directly — two real entries, same filename, different
  rooms); (3) a single copy anywhere still resolves normally (no
  regression to the common case).
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Commonplace.Bots.Identity, as: BotIdentity
  alias Commonplace.Bots.{Citizen, MudContext}
  alias Commonplace.MUD.World
  alias Commonplace.Presence
  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    n = :rand.uniform(1_000_000_000)
    dir = Path.join(System.tmp_dir!(), "cp_bots_forkminter_#{n}")
    File.mkdir_p!(dir)
    store = :"forkminter_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"forkminter_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"forkminter_tss_#{n}",
       pending_imports_name: :"forkminter_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    # PIN (1)/(3) move a presence externally, which takes green tokens
    # (World.move_presence -> Move.move -> Bursar).
    case GenServer.whereis(Commonplace.Green.Bursar) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
    end

    {:ok, bursar_pid} =
      Commonplace.Green.Bursar.start_link(
        root_uuid: UUID.uuid4(),
        store: store,
        sweep_interval: 60_000
      )

    secrets_dir = Path.join(System.tmp_dir!(), "cp_bots_forkminter_secrets_#{n}")
    File.mkdir_p!(secrets_dir)
    secrets = :"forkminter_secrets_#{n}"
    {:ok, secrets_pid} = SecretStore.start_link(data_dir: secrets_dir, name: secrets)

    on_exit(fn ->
      Application.put_env(:commonplace, :data_dir, old_data_dir || "tmp/test_data")

      if Process.alive?(bursar_pid) do
        try do
          GenServer.stop(bursar_pid)
        catch
          :exit, _ -> :ok
        end
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

    {:ok, node_ctx} = Commonplace.Crypto.NodeIdentity.signing_context()
    mud_root = UUID.uuid4()

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

  defp resolve_camillo(ctx) do
    {:ok, prov} = Citizen.provision("camillo", ctx.mud_root, ctx.store, secret_store: ctx.secrets)

    {:ok, sc} =
      BotIdentity.resolve_signing_context("camillo", ctx.mud_root, ctx.store,
        secret_store: ctx.secrets
      )

    {:ok, mud_ctx} = MudContext.resolve(%{name: "camillo"}, sc, ctx.mud_root, ctx.store)
    {prov, sc, mud_ctx}
  end

  # Count every `camillo.usr` entry anywhere under home/foyer/study — the
  # complete set of rooms `Citizen.provision/4` seeds.
  defp count_camillo_usr(prov, store) do
    (World.list_entries(prov.home_room_uuid, store) ++
       World.list_entries(prov.foyer_uuid, store) ++
       World.list_entries(prov.study_uuid, store))
    |> Enum.count(&(&1.name == "camillo.usr"))
  end

  ## ---- PIN (1): re-provision while standing elsewhere is a NO-OP ----

  test "PIN (1): re-provisioning while standing in a non-foyer room is a NO-OP (exactly one .usr, no relocation)",
       ctx do
    {prov, sc, mud_ctx} = resolve_camillo(ctx)

    # Walk him to the Study — externally, as if a prior turn moved him.
    assert :ok =
             World.move_presence(
               mud_ctx.presence_uuid,
               "camillo.usr",
               prov.foyer_uuid,
               prov.study_uuid,
               store: ctx.store,
               signing_context: sc,
               cert_cids: mud_ctx.cert_cids,
               signer_id: mud_ctx.signer_id,
               viewer: sc.identity_uuid
             )

    assert count_camillo_usr(prov, ctx.store) == 1
    assert {:ok, room_before} = World.find_presence_room(ctx.mud_root, "camillo.usr", ctx.store)
    assert room_before == prov.study_uuid

    # RE-PROVISION — the exact ceremony a dispatcher restart / re-register
    # replays. This must be a NO-OP: no new presence, no relocation.
    assert {:ok, _reprov} =
             Citizen.provision("camillo", ctx.mud_root, ctx.store, secret_store: ctx.secrets)

    assert count_camillo_usr(prov, ctx.store) == 1

    assert {:ok, room_after} = World.find_presence_room(ctx.mud_root, "camillo.usr", ctx.store)
    assert room_after == prov.study_uuid
  end

  ## ---- PIN (2): duplicates -> find_presence refuses AND logs ----

  test "PIN (2): a duplicate filename in two rooms makes find_presence refuse-and-degrade, logged",
       ctx do
    {prov, sc, mud_ctx} = resolve_camillo(ctx)

    # Construct a genuine fork DIRECTLY: a second `camillo.usr` minted
    # straight into the Study, bypassing provision/move entirely (the
    # duplicate itself, not how it got there, is what's under test).
    {:ok, _dup_uuid} =
      Presence.create("camillo", :usr, prov.study_uuid, ctx.store,
        signing_context: sc,
        cert_cids: mud_ctx.cert_cids,
        signer_id: mud_ctx.signer_id
      )

    assert count_camillo_usr(prov, ctx.store) == 2

    log =
      capture_log(fn ->
        assert {:error, :ambiguous_presence} =
                 World.find_presence(ctx.mud_root, "camillo.usr", ctx.store)
      end)

    assert log =~ "AMBIGUOUS"
    assert log =~ "camillo.usr"

    # The room-only variant collapses the same ambiguity to :not_found
    # (its existing 2-value contract, never a crash).
    assert :not_found = World.find_presence_room(ctx.mud_root, "camillo.usr", ctx.store)
  end

  ## ---- PIN (3): a single copy anywhere still resolves normally ----

  test "PIN (3): a single presence anywhere (not just the foyer) still resolves normally — no regression",
       ctx do
    {prov, sc, mud_ctx} = resolve_camillo(ctx)

    assert :ok =
             World.move_presence(
               mud_ctx.presence_uuid,
               "camillo.usr",
               prov.foyer_uuid,
               prov.study_uuid,
               store: ctx.store,
               signing_context: sc,
               cert_cids: mud_ctx.cert_cids,
               signer_id: mud_ctx.signer_id,
               viewer: sc.identity_uuid
             )

    assert {:ok, room_uuid, presence_uuid} =
             World.find_presence(ctx.mud_root, "camillo.usr", ctx.store)

    assert room_uuid == prov.study_uuid
    assert presence_uuid == mud_ctx.presence_uuid

    assert {:ok, room_uuid2} = World.find_presence_room(ctx.mud_root, "camillo.usr", ctx.store)
    assert room_uuid2 == prov.study_uuid
  end
end

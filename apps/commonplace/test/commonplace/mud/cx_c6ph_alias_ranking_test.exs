defmodule Commonplace.MUD.CXc6phAliasRankingTest do
  @moduledoc """
  CX-c6ph — noun resolution must rank by match QUALITY across dirs
  (exact-name beats an alias/partial match found in an earlier-searched
  dir), not just take the first dir's match. Repro: a room holds a
  "vault" object (exact name); the player carries a "brass key" whose
  ALIAS is "vault key" (substring match on "vault"). Before the fix,
  `examine vault` resolved to the carried brass key (inventory searched
  first, `find_entry_in_dirs/3` had no quality ranking) instead of the
  room's exact-named vault.

  Setup mirrors `Commonplace.MUD.VerbsSafeDispatchTest` (named
  `Commonplace.Store.Supervisor` trio + `Commonplace.Green.Bursar`
  bring-up) — copied faithfully for harness parity.
  """
  use ExUnit.Case, async: false

  alias Commonplace.MUD.{Parser, Schemas, SignedWrite, Verbs}
  alias Commonplace.MUD.Schemas.{Object, Room}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    dir = Path.join(System.tmp_dir!(), "cp_cx_c6ph_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"cx_c6ph_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"cx_c6ph_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"cx_c6ph_tss_#{n}",
       pending_imports_name: :"cx_c6ph_pi_#{n}"}
    )

    case GenServer.whereis(Commonplace.Green.Bursar) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    root_uuid = UUID.uuid4()

    {:ok, bursar_pid} =
      Commonplace.Green.Bursar.start_link(
        root_uuid: root_uuid,
        store: store,
        sweep_interval: 60_000
      )

    on_exit(fn ->
      if Process.alive?(bursar_pid),
        do:
          (try do
             GenServer.stop(bursar_pid)
           catch
             (:exit, _ -> :ok)
           end)

      File.rm_rf!(dir)
    end)

    Commonplace.Code.SourceDoc.reset_cache()

    {:ok, room_uuid} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Room{name: "The Yard", description: "a plain stone yard"}),
        store
      )

    {:ok, inventory_uuid} = Schemas.create_dir_with_meta(nil, nil, store)

    %{store: store, root_uuid: root_uuid, room_uuid: room_uuid, inventory_uuid: inventory_uuid}
  end

  # ---- test helpers (mirrors VerbsSafeDispatchTest) ----

  defp base_ctx(store, room_uuid, inventory_uuid, opts \\ []) do
    %{
      player_name: Keyword.get(opts, :player_name, "alice"),
      player_uuid: Keyword.get(opts, :player_uuid, UUID.uuid4()),
      player_dir_uuid: Keyword.get(opts, :player_dir_uuid, UUID.uuid4()),
      inventory_uuid: inventory_uuid,
      current_room_uuid: room_uuid,
      presence_filename: "alice.usr",
      root_uuid: Keyword.get(opts, :root_uuid, UUID.uuid4()),
      store: store,
      signing_context: Keyword.get(opts, :signing_context),
      signer_id: Keyword.get(opts, :signer_id),
      cert_cids: Keyword.get(opts, :cert_cids, [])
    }
  end

  defp add_dir_entry(store, parent_uuid, name, child_uuid, opts \\ []) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_directory(schema, name, child_uuid)
    update = Encoding.encode_update(schema)
    {metadata, commit_opts} = SignedWrite.opts_for(parent_uuid, Keyword.put(opts, :store, store))

    case CommitStoreClient.create_chained_commit(
           store,
           parent_uuid,
           update,
           metadata,
           commit_opts
         ) do
      {:error, _} = err -> err
      _commit -> :ok
    end
  end

  defp create_object(store, %Object{} = obj, opts \\ []) do
    {:ok, uuid} =
      Schemas.create_dir_with_meta(
        Schemas.object_filename(),
        Schemas.encode_object(obj),
        store,
        opts
      )

    uuid
  end

  # ---- CX-c6ph pins ----

  test "pin A: `examine vault` resolves to the room's exact-named vault, not an aliased inventory item",
       %{
         store: store,
         room_uuid: room_uuid,
         inventory_uuid: inventory_uuid
       } do
    vault_uuid = create_object(store, %Object{name: "vault", description: "a squat iron vault"})
    :ok = add_dir_entry(store, room_uuid, "vault.obj", vault_uuid)

    key_uuid =
      create_object(store, %Object{
        name: "brass key",
        description: "a small brass key",
        aliases: ["vault key"]
      })

    :ok = add_dir_entry(store, inventory_uuid, "brass key.obj", key_uuid)

    ctx = base_ctx(store, room_uuid, inventory_uuid)

    assert {:reply, text} = Verbs.dispatch(Parser.parse("examine vault"), ctx)
    assert text =~ "vault"
    refute text =~ "brass key"
  end

  test "pin B: exact-name beats alias-partial even though inventory is searched first in dir order",
       %{
         store: store,
         room_uuid: room_uuid,
         inventory_uuid: inventory_uuid
       } do
    vault_uuid = create_object(store, %Object{name: "vault", description: "a squat iron vault"})
    :ok = add_dir_entry(store, room_uuid, "vault.obj", vault_uuid)

    key_uuid =
      create_object(store, %Object{
        name: "brass key",
        description: "a small brass key",
        aliases: ["vault key"]
      })

    :ok = add_dir_entry(store, inventory_uuid, "brass key.obj", key_uuid)

    ctx = base_ctx(store, room_uuid, inventory_uuid)

    assert {:reply, text} = Verbs.dispatch(Parser.parse("examine vault"), ctx)
    assert text =~ "squat iron vault"
    refute text =~ "small brass key"
  end

  test "pin C: `examine brass key` still resolves to the carried key itself (no regression)", %{
    store: store,
    room_uuid: room_uuid,
    inventory_uuid: inventory_uuid
  } do
    vault_uuid = create_object(store, %Object{name: "vault", description: "a squat iron vault"})
    :ok = add_dir_entry(store, room_uuid, "vault.obj", vault_uuid)

    key_uuid =
      create_object(store, %Object{
        name: "brass key",
        description: "a small brass key",
        aliases: ["vault key"]
      })

    :ok = add_dir_entry(store, inventory_uuid, "brass key.obj", key_uuid)

    ctx = base_ctx(store, room_uuid, inventory_uuid)

    assert {:reply, text} = Verbs.dispatch(Parser.parse("examine brass key"), ctx)
    assert text =~ "small brass key"
    refute text =~ "squat iron vault"
  end
end

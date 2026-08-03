defmodule Commonplace.MUD.BotFullCitizenshipTest do
  @moduledoc """
  CX-gjpi regression — the full-citizenship root-resolution path.

  A bot launched WITHOUT an explicit `:root_uuid` and with
  `:mud_full_citizenship` enabled resolves its spawn root through
  `Bot.resolve_root/1 → mud_world_root/2`, which reconstructs the
  workspace root, walks to its "mud" child, and roots the session there
  (co-present with web citizens whose `MudLive` is rooted in the same
  subtree).

  This path was NEVER exercised by `BotTest` because every case there
  passes `root_uuid:` explicitly (bypassing `resolve_root`) AND runs the
  starter path (`full_citizenship?/0` false). That masked a latent bug:
  `bot.ex` referenced a bare, UNALIASED `CommitStoreClient`, which the
  compiler resolves to the atom `Elixir.CommitStoreClient` — a module
  that does not exist. `CommitStoreClient.normalize_server/1` only maps
  its OWN `Commonplace.Store.CommitStoreClient` back to `CommitStore`, so
  the bogus atom fell through untouched into `resolve_db/1` and blew up
  with `GenServer.call(CommitStoreClient, :get_db)` → `:noproc` on the
  live serve (the exact crash agent-citizen launch hit). The fix aliases
  the module AND threads the bot's configured `store` into the loader so
  the path is reachable with a custom store — which is what this test
  uses.
  """
  use ExUnit.Case, async: false

  alias Commonplace.MUD.{Bootstrap, Bot, World}
  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    n = :rand.uniform(1_000_000_000)
    dir = Path.join(System.tmp_dir!(), "cp_fullcit_#{n}")
    File.mkdir_p!(dir)
    store = :"fullcit_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"fullcit_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"fullcit_tss_#{n}",
       pending_imports_name: :"fullcit_pi_#{n}"}
    )

    secrets_dir = Path.join(System.tmp_dir!(), "cp_fullcit_secrets_#{n}")
    File.mkdir_p!(secrets_dir)
    secrets_name = :"fullcit_secrets_#{n}"
    {:ok, secrets_pid} = SecretStore.start_link(data_dir: secrets_dir, name: secrets_name)

    # CX-vj8v: Bot.spawn_session now takes a cluster-exclusivity green
    # token before spawning — start a Bursar under its default name so
    # the default `bursar:` route finds it (same setup shape as
    # bot_test.exs / bot_presence_cert_test.exs).
    case GenServer.whereis(Commonplace.Green.Bursar) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, bursar_pid} =
      Commonplace.Green.Bursar.start_link(
        root_uuid: UUID.uuid4(),
        store: store,
        sweep_interval: 60_000
      )

    on_exit(fn ->
      if Process.alive?(bursar_pid),
        do: (try do GenServer.stop(bursar_pid) catch (:exit, _ -> :ok) end)
    end)

    # The migrated shape: a workspace root whose "mud" child IS the
    # curated world. Seed the world under the CHILD, then link it in.
    mud_root = UUID.uuid4()
    CommitStore.create_commit(store, mud_root, Encoding.encode_update(Schema.new_schema()), nil)
    {:ok, _} = Bootstrap.seed(mud_root, store)

    workspace_root = UUID.uuid4()
    root_schema = Schema.new_schema() |> Schema.add_directory("mud", mud_root)
    CommitStore.create_commit(store, workspace_root, Encoding.encode_update(root_schema), nil)

    # `Workspace.root_uuid/0` reads `<:data_dir>/root`; point it at the
    # workspace root so `resolve_root/1` finds it, and flip on full
    # citizenship so `resolve_root/1` walks to the "mud" child.
    # Save under the REAL app-env keys — the restore loop feeds these map
    # keys straight to Application.put_env/delete_env, so a shorthand key
    # (e.g. `:full`) would restore the WRONG key and leak
    # `:mud_full_citizenship = true` into every later test file (CX-6hxa).
    old = %{
      data_dir: Application.get_env(:commonplace, :data_dir),
      mud_full_citizenship: Application.get_env(:commonplace, :mud_full_citizenship)
    }

    File.write!(Path.join(dir, "root"), workspace_root)
    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :mud_full_citizenship, true)

    on_exit(fn ->
      Bot.stop("regcitizen")
      if Process.alive?(secrets_pid), do: (try do GenServer.stop(secrets_pid) catch (:exit, _ -> :ok) end)

      for {k, v} <- old do
        if is_nil(v),
          do: Application.delete_env(:commonplace, k),
          else: Application.put_env(:commonplace, k, v)
      end

      File.rm_rf!(dir)
      File.rm_rf!(secrets_dir)
    end)

    %{store: store, secrets: secrets_name, mud_root: mud_root, workspace_root: workspace_root}
  end

  test "full-citizen bot with no :root_uuid resolves into the 'mud' subtree (not :noproc)", ctx do
    # No :root_uuid → drives resolve_root/1 → mud_world_root/2 (the path
    # that crashed with GenServer.call(CommitStoreClient, :get_db) before
    # the alias + store-threading fix).
    result = Bot.send_input("regcitizen", "look", store: ctx.store, secret_store: ctx.secrets, settle_ms: 150)

    assert {:ok, events} = result
    assert is_list(events)
    # A real render, never the crash/teardown sentinels.
    text = Enum.join(events, "\n")
    refute text =~ "clean disconnect"

    # The presence must live in the MUD subtree — proof the session rooted
    # at the "mud" child (via the store-threaded loader), not the bare
    # workspace root. A wrong-store loader would fall back to
    # workspace_root and the presence would NOT be reachable from mud_root.
    assert {:ok, _room_uuid, _presence_uuid} =
             World.find_presence(ctx.mud_root, "regcitizen.usr", ctx.store)
  end
end

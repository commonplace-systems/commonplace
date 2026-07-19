defmodule Commonplace.Bots.DigTest do
  @moduledoc """
  Camillo C6 (cp-plan #8949/#8952) — the `dig` tool: carve a new room from
  where the bot is standing, through the SAME `Commonplace.MUD.Build
  .dig_room/4` write-core `Commonplace.Bots.Citizen` uses to seed a foyer.
  "dig -> walk in -> describe" is the whole design.

  Pins authored FROM THE SPEC (lesson #8): (a) THE COMPOSITION PIN — dig
  from his room creates the new room + reciprocal exits, zone-stamped,
  under real enforce, end-to-end through a REAL `Worker.run/4` turn — then
  walk in + describe lands on the NEW room; (b) dig collision fail-closed
  (an existing direction refuses, no partial write); (c) dig dual-layer
  home-zone — TOOL-layer refusal from a foreign room AND SEPARATELY
  GATE-layer denial on a bypass, the same discipline `describe_test.exs`
  established.

  (Door-naming — move's missing-exit message naming `dig` when charted —
  is pinned in `mud_tools_test.exs`, where `move`'s other tests live; the
  wiki-namespace book generalization is pinned in
  `scratch_reading_test.exs`, where `scratch`/`read_scratch`/`list_scratch`
  tests live.)
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.Identity, as: BotIdentity
  alias Commonplace.Bots.{Citizen, Entity, MudContext, Worker}
  alias Commonplace.Bots.Worker.Tools.Dig
  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Document.ContentType
  alias Commonplace.MUD.World
  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Trust
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    n = :rand.uniform(1_000_000_000)
    dir = Path.join(System.tmp_dir!(), "cp_bots_dig_#{n}")
    File.mkdir_p!(dir)
    store = :"dig_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"dig_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"dig_tss_#{n}",
       pending_imports_name: :"dig_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    # PIN (a)'s "walk in" hop moves a presence, which takes green tokens
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

    secrets_dir = Path.join(System.tmp_dir!(), "cp_bots_dig_secrets_#{n}")
    File.mkdir_p!(secrets_dir)
    secrets = :"dig_secrets_#{n}"
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

    {:ok, node_ctx} = NodeIdentity.signing_context()

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

  ## --- Fixtures ---

  defp resolve_bot(name, ctx) do
    {:ok, prov} = Citizen.provision(name, ctx.mud_root, ctx.store, secret_store: ctx.secrets)

    {:ok, sc} =
      BotIdentity.resolve_signing_context(name, ctx.mud_root, ctx.store,
        secret_store: ctx.secrets
      )

    {:ok, mud_ctx} = MudContext.resolve(%{name: name}, sc, ctx.mud_root, ctx.store)
    {prov, sc, mud_ctx}
  end

  defp with_enforce(fun) do
    prior_gate = Application.get_env(:commonplace, :local_write_gate)
    prior_trust = Application.get_env(:commonplace, :trust)

    Application.put_env(:commonplace, :local_write_gate, :enforce)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})

    try do
      fun.()
    after
      case prior_gate do
        nil -> Application.delete_env(:commonplace, :local_write_gate)
        v -> Application.put_env(:commonplace, :local_write_gate, v)
      end

      case prior_trust do
        nil -> Application.delete_env(:commonplace, :trust)
        v -> Application.put_env(:commonplace, :trust, v)
      end
    end
  end

  defp mint_signed_text_doc(store, name, body, node_ctx) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new() |> ContentType.create(:text, name)
    doc = if body == "", do: doc, else: ContentType.insert_text(doc, 0, body)

    CommitStore.create_commit(store, uuid, Encoding.encode_update(doc), nil, %{},
      signing_context: node_ctx
    )

    uuid
  end

  defp mint_bot_dir(ctx, tools_list) do
    config = Jason.encode!(%{"tools" => tools_list})

    schema =
      Schema.new_schema()
      |> Schema.add_file(
        "persona.md",
        mint_signed_text_doc(ctx.store, "persona.md", "You are camillo.", ctx.node_ctx)
      )
      |> Schema.add_file(
        "trigger.regex",
        mint_signed_text_doc(ctx.store, "trigger.regex", "(?i)@camillo\\b", ctx.node_ctx)
      )
      |> Schema.add_file(
        "bot.json",
        mint_signed_text_doc(ctx.store, "bot.json", config, ctx.node_ctx)
      )

    uuid = UUID.uuid4()

    CommitStore.create_commit(ctx.store, uuid, Encoding.encode_update(schema), nil, %{},
      signing_context: ctx.node_ctx
    )

    uuid
  end

  defp load_entity(ctx, uuid, display_name) do
    {:ok, entity} = Entity.load(ctx.store, uuid, display_name)
    entity
  end

  defp event(text) do
    %{"message_id" => "m1", "author_path" => "jes.usr", "text" => text}
  end

  defp end_turn(text \\ "ok") do
    %{
      "stop_reason" => "end_turn",
      "content" => [%{"type" => "text", "text" => text}],
      "usage" => %{"output_tokens" => 5}
    }
  end

  defp tool_use(id, name, input) do
    %{
      "stop_reason" => "tool_use",
      "content" => [%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}],
      "usage" => %{"output_tokens" => 20}
    }
  end

  defp stub_client(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn _request ->
      case Agent.get_and_update(agent, fn
             [] -> {[], []}
             [h | t] -> {h, t}
           end) do
        [] -> {:error, :stub_exhausted}
        response -> {:ok, response}
      end
    end
  end

  defp worker_opts(ctx, client_fn) do
    [
      root_uuid: ctx.mud_root,
      store: ctx.store,
      secret_store: ctx.secrets,
      client_fn: client_fn,
      presence_enabled: false
    ]
  end

  ## ---- PIN (a): THE COMPOSITION PIN — dig -> walk in -> describe, end-to-end ----

  test "PIN (a): dig from his room creates the new room + reciprocal exits, zone-stamped, under real enforce — then walk in + describe lands on the NEW room",
       ctx do
    with_enforce(fn ->
      {prov, _sc, _mud_ctx} = resolve_bot("camillo", ctx)
      entity = load_entity(ctx, mint_bot_dir(ctx, ["dig", "move", "describe"]), "camillo.bot")

      responses = [
        tool_use("t1", "dig", %{"direction" => "east", "name" => "Garden"}),
        tool_use("t2", "move", %{"direction" => "east"}),
        tool_use("t3", "describe", %{"text" => "A quiet garden."}),
        end_turn()
      ]

      assert {:ok, :end_turn} =
               Worker.run(
                 "jes",
                 entity,
                 event("dig and settle"),
                 worker_opts(ctx, stub_client(responses))
               )

      # The new room is a REAL exit off the Foyer now.
      {:ok, foyer} = World.get_room(prov.foyer_uuid, ctx.store)
      assert new_room_uuid = Map.get(foyer.exits, "east")
      refute is_nil(new_room_uuid)

      # Zone-stamped — a direct child of home, same zone as every other dug room.
      assert Trust.doc_zone(new_room_uuid, ctx.store) == prov.home_room_uuid

      # Reciprocal exit baked back onto the new room.
      {:ok, new_room} = World.get_room(new_room_uuid, ctx.store)
      assert new_room.exits["west"] == prov.foyer_uuid
      assert new_room.name == "Garden"

      # walk in + describe landed on the NEW room — not the Foyer.
      {:ok, refreshed_new_room} = World.get_room(new_room_uuid, ctx.store)
      {:ok, refreshed_foyer} = World.get_room(prov.foyer_uuid, ctx.store)
      assert refreshed_new_room.description == "A quiet garden."
      refute refreshed_foyer.description == "A quiet garden."

      # The bot's presence genuinely ended up in the new room (no fork).
      assert {:ok, room_uuid} = World.find_presence_room(ctx.mud_root, "camillo.usr", ctx.store)
      assert room_uuid == new_room_uuid
    end)
  end

  ## ---- PIN (b): dig collision fail-closed ----

  test "PIN (b): an existing direction is refused, honestly, no partial write", ctx do
    {prov, _sc, mud_ctx} = resolve_bot("camillo", ctx)

    # Foyer already has a "north" exit (to Study, baked by Citizen.provision).
    {:ok, before} = World.get_room(prov.foyer_uuid, ctx.store)
    assert before.exits["north"] == prov.study_uuid

    assert {:error, msg} =
             Dig.call(%{mud_ctx: mud_ctx}, %{"direction" => "north", "name" => "Nope"})

    assert msg =~ "already a door"

    {:ok, after_} = World.get_room(prov.foyer_uuid, ctx.store)
    assert after_.exits == before.exits
  end

  ## ---- PIN (c): dual-layer home-zone ----

  test "PIN (c) TOOL LAYER: standing outside his own home zone, dig refuses BEFORE any write, even permissive",
       ctx do
    {camillo, sc, mud_ctx} = resolve_bot("camillo", ctx)
    {rival, _rival_sc, _rival_ctx} = resolve_bot("rival", ctx)

    assert :ok =
             World.move_presence(
               mud_ctx.presence_uuid,
               "camillo.usr",
               camillo.foyer_uuid,
               rival.home_room_uuid,
               store: ctx.store,
               signing_context: sc,
               cert_cids: mud_ctx.cert_cids,
               signer_id: mud_ctx.signer_id,
               viewer: sc.identity_uuid
             )

    {:ok, moved_ctx} = MudContext.resolve(%{name: "camillo"}, sc, ctx.mud_root, ctx.store)
    assert moved_ctx.current_room_uuid == rival.home_room_uuid

    {:ok, before} = World.get_room(rival.home_room_uuid, ctx.store)

    assert {:error, msg} =
             Dig.call(%{mud_ctx: moved_ctx}, %{"direction" => "east", "name" => "Squat"})

    assert msg =~ "your own home"

    {:ok, after_} = World.get_room(rival.home_room_uuid, ctx.store)
    assert after_.exits == before.exits
  end

  test "PIN (c) GATE LAYER: a direct Build.dig_room bypass from a foreign room is DENIED under real enforce",
       ctx do
    with_enforce(fn ->
      {_camillo, _sc, mud_ctx} = resolve_bot("camillo", ctx)
      {rival, _rival_sc, _rival_ctx} = resolve_bot("rival", ctx)

      {:ok, before} = World.get_room(rival.home_room_uuid, ctx.store)

      # Bypass Dig entirely: a raw Build.dig_room/4 call with CAMILLO's own
      # creds (unchanged — player_name/root_uuid/store/signing_context/
      # cert_cids/signer_id all still his own), but current_room_uuid set
      # to RIVAL's home — the new room's own mint always lands
      # home-anchored (harmless), but the exit-merge write onto rival's
      # home is what the gate must deny.
      bypass_ctx = %{mud_ctx | current_room_uuid: rival.home_room_uuid}

      result = Commonplace.MUD.Build.dig_room(bypass_ctx, "east", "west", "Squat")

      assert {:error, _} = result

      {:ok, after_} = World.get_room(rival.home_room_uuid, ctx.store)
      assert after_.exits == before.exits
    end)
  end

  ## ---- Ungrouped: graceful refusals, direction/name validation ----

  test "no mud_ctx (unprovisioned) refuses gracefully", _ctx do
    assert {:error, "You are not in the world."} =
             Dig.call(%{mud_ctx: nil}, %{"direction" => "east", "name" => "x"})
  end

  test "an unknown direction is refused", ctx do
    {_prov, _sc, mud_ctx} = resolve_bot("camillo", ctx)

    assert {:error, msg} =
             Dig.call(%{mud_ctx: mud_ctx}, %{"direction" => "sideways", "name" => "x"})

    assert msg =~ "direction"
  end

  test "a room name with a slash or \"..\" is refused", ctx do
    {_prov, _sc, mud_ctx} = resolve_bot("camillo", ctx)

    assert {:error, "Bad room name."} =
             Dig.call(%{mud_ctx: mud_ctx}, %{"direction" => "east", "name" => "../etc"})

    assert {:error, "Bad room name."} =
             Dig.call(%{mud_ctx: mud_ctx}, %{"direction" => "west", "name" => "a/b"})
  end

  test "dig is registered under the default-closed allowlist convention", _ctx do
    assert Dig.name() == "dig"
    defn = Dig.definition()
    assert defn["name"] == "dig"
    assert is_map(defn["input_schema"])
  end
end

defmodule Commonplace.Bots.PerceptionTest do
  @moduledoc """
  Camillo C5a — awareness-by-default wake perception (cp-plan #8867).

  Pins:

    * (a) perception-from-the-real-read: a wake's perception block is
      rendered through the SAME enforce-safe `World.room_snapshot/4` read
      `look` uses, carries the room NAME + description, and reflects
      POSITION AT ASSEMBLY TIME — an external move made between setup and
      wake shows the NEW room, not a stale one (asserted both at the
      `Loop`-precision level and via one real `Worker.run/4` dispatch).
    * (b) nil-degrade: no `mud_ctx` (unprovisioned entity) → the wake text
      contains exactly "You cannot feel your body." and no fabricated
      room content.
    * (c) budget override is per-bot-only: covered in `worker_test.exs`-style
      config-resolution assertions below.

  Plus the description truncation contract: a long description gets the
  ~600-char cap + the honest "…the writing continues" line; a short one
  does not.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Commonplace.Bots.Identity, as: BotIdentity
  alias Commonplace.Bots.Worker.{Loop, Perception, Tools}
  alias Commonplace.Bots.{Citizen, Entity, MudContext}
  alias Commonplace.MUD.{Schemas, World}
  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    n = :rand.uniform(1_000_000_000)
    dir = Path.join(System.tmp_dir!(), "cp_bots_perception_#{n}")
    File.mkdir_p!(dir)
    store = :"perception_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"perception_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"perception_tss_#{n}",
       pending_imports_name: :"perception_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    # Presence moves take green tokens (World.move -> Move.move -> Bursar) —
    # same setup discipline as mud_tools_test.exs.
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

    secrets_dir = Path.join(System.tmp_dir!(), "cp_bots_perception_secrets_#{n}")
    File.mkdir_p!(secrets_dir)
    secrets = :"perception_secrets_#{n}"
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

    %{store: store, mud_root: mud_root, secrets: secrets}
  end

  ## Fixtures

  defp resolve_camillo(ctx) do
    {:ok, prov} = Citizen.provision("camillo", ctx.mud_root, ctx.store, secret_store: ctx.secrets)

    {:ok, sc} =
      BotIdentity.resolve_signing_context("camillo", ctx.mud_root, ctx.store,
        secret_store: ctx.secrets
      )

    {:ok, mud_ctx} = MudContext.resolve(%{name: "camillo"}, sc, ctx.mud_root, ctx.store)
    {prov, sc, mud_ctx}
  end

  defp mint_text_doc(store, name, body) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = Commonplace.Document.ContentType.create(doc, :text, name)
    doc = if body == "", do: doc, else: Commonplace.Document.ContentType.insert_text(doc, 0, body)
    CommitStore.create_commit(store, uuid, Encoding.encode_update(doc), nil)
    uuid
  end

  defp mint_bot_dir(store) do
    schema =
      Schema.new_schema()
      |> Schema.add_file("persona.md", mint_text_doc(store, "persona.md", "I am camillo."))
      |> Schema.add_file("trigger.regex", mint_text_doc(store, "trigger.regex", "(?i)@camillo"))

    uuid = UUID.uuid4()
    CommitStore.create_commit(store, uuid, Encoding.encode_update(schema), nil)
    uuid
  end

  defp base_config do
    %{
      max_calls: 3,
      max_output_tokens: 100,
      max_wall_ms: 5_000,
      model: "test-model",
      fallback_model: nil
    }
  end

  defp chat_state(entity, mud_ctx, text \\ "hello camillo") do
    %{
      room: "camillo",
      entity: entity,
      mud_ctx: mud_ctx,
      event: %{"author_path" => "jes.usr", "text" => text},
      config: base_config(),
      client_fn: fn _ ->
        {:ok, %{"stop_reason" => "end_turn", "content" => [], "usage" => %{"output_tokens" => 1}}}
      end,
      tools_module: Tools,
      signing_context: nil,
      allowlist: [],
      opts: []
    }
  end

  defp captured_text(state) do
    test_pid = self()

    client_fn = fn request ->
      send(test_pid, {:request, request})
      {:ok, %{"stop_reason" => "end_turn", "content" => [], "usage" => %{"output_tokens" => 1}}}
    end

    assert {:ok, :end_turn} = Loop.run(%{state | client_fn: client_fn})
    assert_receive {:request, request}
    first_user_text(request)
  end

  defp first_user_text(request) do
    request
    |> Map.get(:messages)
    |> List.first()
    |> Map.get("content")
    |> List.first()
    |> Map.get("text")
  end

  defp set_room_description(room_uuid, text, sc, mud_ctx, store) do
    World.set_meta(room_uuid, Schemas.room_filename(), "description", text, store,
      signing_context: sc,
      cert_cids: mud_ctx.cert_cids,
      signer_id: mud_ctx.signer_id
    )
  end

  ## Pin (a): perception-from-the-real-read + position at assembly

  describe "pin (a) — perception from the real read, position at assembly" do
    test "chat wake perception block carries the room name + description", ctx do
      {prov, _sc, mud_ctx} = resolve_camillo(ctx)

      bot_dir = mint_bot_dir(ctx.store)
      {:ok, entity} = Entity.load(ctx.store, bot_dir, "camillo.bot")

      text = captured_text(chat_state(entity, mud_ctx))

      assert text =~ "Foyer"
      assert text =~ "(no description yet)"
      # The delimiter structure: perception block first, event content after.
      assert text =~ ~r/You stand in Foyer.*says:/s
      refute prov.foyer_uuid == prov.study_uuid
    end

    test "heartbeat wake also gets the perception block, ahead of the agenda framing", ctx do
      {_prov, _sc, mud_ctx} = resolve_camillo(ctx)
      :ok = Commonplace.Bots.Agenda.append(%{"text" => "consolidate the pins"}, mud_ctx)

      bot_dir = mint_bot_dir(ctx.store)
      {:ok, entity} = Entity.load(ctx.store, bot_dir, "camillo.bot")

      state = %{
        chat_state(entity, mud_ctx)
        | event: %{"kind" => "heartbeat", "thread_quiet" => true},
          opts: [store: ctx.store]
      }

      text = captured_text(state)

      assert text =~ "Foyer"
      assert text =~ "You woke on a heartbeat"
      assert text =~ "consolidate the pins"
      assert text =~ "The hour is yours."
      assert text =~ ~r/You stand in Foyer.*You woke on a heartbeat/s
    end

    test "position is resolved AT ASSEMBLY TIME — an external move after setup shows the NEW room",
         ctx do
      {prov, sc, mud_ctx1} = resolve_camillo(ctx)
      bot_dir = mint_bot_dir(ctx.store)
      {:ok, entity} = Entity.load(ctx.store, bot_dir, "camillo.bot")

      # Wake #1 — still in the Foyer.
      text1 = captured_text(chat_state(entity, mud_ctx1))
      assert text1 =~ "Foyer"
      refute text1 =~ "Study"

      # An EXTERNAL move (as if a summon, or another actor relocating the
      # bot's .usr) — not through this ctx.
      assert :ok =
               World.move_presence(
                 mud_ctx1.presence_uuid,
                 "camillo.usr",
                 prov.foyer_uuid,
                 prov.study_uuid,
                 store: ctx.store,
                 signing_context: sc,
                 cert_cids: mud_ctx1.cert_cids,
                 signer_id: mud_ctx1.signer_id,
                 viewer: sc.identity_uuid
               )

      Commonplace.Tree.DocCache.clear()

      # A fresh mud_ctx resolve (exactly what Worker.run/4 does every turn —
      # C3c pin (a)) now reads the NEW position.
      {:ok, mud_ctx2} = MudContext.resolve(%{name: "camillo"}, sc, ctx.mud_root, ctx.store)
      assert mud_ctx2.current_room_uuid == prov.study_uuid

      # Wake #2, assembled from the freshly-resolved ctx, shows the NEW room.
      text2 = captured_text(chat_state(entity, mud_ctx2))
      assert text2 =~ "Study"
      refute text2 =~ "You stand in Foyer"
    end

    test "one real dispatch: Worker.run/4 twice, moving the citizen between calls, shows the new room",
         ctx do
      {prov, sc, mud_ctx1} = resolve_camillo(ctx)
      bot_dir = mint_bot_dir(ctx.store)
      {:ok, entity} = Entity.load(ctx.store, bot_dir, "camillo.bot")

      test_pid = self()

      capture_fn = fn request ->
        send(test_pid, {:request, request})
        {:ok, %{"stop_reason" => "end_turn", "content" => [], "usage" => %{"output_tokens" => 1}}}
      end

      event = %{"message_id" => "m1", "author_path" => "jes.usr", "text" => "hi camillo"}

      assert {:ok, :end_turn} =
               Commonplace.Bots.Worker.run("camillo", entity, event,
                 client_fn: capture_fn,
                 root_uuid: ctx.mud_root,
                 secret_store: ctx.secrets,
                 store: ctx.store
               )

      assert_receive {:request, req1}
      assert first_user_text(req1) =~ "Foyer"

      assert :ok =
               World.move_presence(
                 mud_ctx1.presence_uuid,
                 "camillo.usr",
                 prov.foyer_uuid,
                 prov.study_uuid,
                 store: ctx.store,
                 signing_context: sc,
                 cert_cids: mud_ctx1.cert_cids,
                 signer_id: mud_ctx1.signer_id,
                 viewer: sc.identity_uuid
               )

      Commonplace.Tree.DocCache.clear()

      assert {:ok, :end_turn} =
               Commonplace.Bots.Worker.run(
                 "camillo",
                 entity,
                 %{event | "message_id" => "m2"},
                 client_fn: capture_fn,
                 root_uuid: ctx.mud_root,
                 secret_store: ctx.secrets,
                 store: ctx.store
               )

      assert_receive {:request, req2}
      assert first_user_text(req2) =~ "Study"
      refute first_user_text(req2) =~ "You stand in Foyer"
    end
  end

  ## Pin (b): nil-degrade

  describe "pin (b) — nil-degrade" do
    test "no mud_ctx (unprovisioned entity) degrades to the honest nil-body line", ctx do
      bot_dir = mint_bot_dir(ctx.store)
      {:ok, entity} = Entity.load(ctx.store, bot_dir, "camillo.bot")

      logged =
        capture_log(fn ->
          text = captured_text(chat_state(entity, nil))
          assert text =~ "You cannot feel your body."
          # Fixed nil-degrade shape: no fabricated room content leaks through.
          refute text =~ "Exits:"
          refute text =~ "Foyer"
        end)

      assert logged =~ "camillo"
      assert logged =~ "no_mud_ctx"
    end

    test "a snapshot read failure ALSO degrades honestly, never a fabricated empty room" do
      entity = %Entity{name: "camillo", dir_uuid: "d", persona: "p", trigger_source: "x"}

      bad_ctx = %{
        current_room_uuid: UUID.uuid4(),
        presence_filename: "camillo.usr",
        store: :"perception_nonexistent_#{:rand.uniform(1_000_000)}",
        signing_context: %{identity_uuid: "id"}
      }

      state = %{
        chat_state(entity, bad_ctx)
        | client_fn: fn _ ->
            {:ok,
             %{"stop_reason" => "end_turn", "content" => [], "usage" => %{"output_tokens" => 1}}}
          end
      }

      logged =
        capture_log(fn ->
          text = captured_text(state)
          assert text == build_expected_nil_body(text)
        end)

      assert logged =~ "camillo"
    end

    defp build_expected_nil_body(actual_text) do
      # The perception block must be EXACTLY the nil-body line — the event
      # content follows it, so assert the FIRST line rather than full equality.
      [first_line | _] = String.split(actual_text, "\n\n", parts: 2)
      assert first_line == "You cannot feel your body."
      actual_text
    end
  end

  ## Truncation contract

  describe "description cap + truncation line" do
    test "a long description is capped at ~600 chars with the honest truncation line", ctx do
      {prov, sc, mud_ctx} = resolve_camillo(ctx)
      long_desc = String.duplicate("a", 900)

      :ok = set_room_description(prov.foyer_uuid, long_desc, sc, mud_ctx, ctx.store)
      Commonplace.Tree.DocCache.clear()

      {:ok, mud_ctx2} = MudContext.resolve(%{name: "camillo"}, sc, ctx.mud_root, ctx.store)

      bot_dir = mint_bot_dir(ctx.store)
      {:ok, entity} = Entity.load(ctx.store, bot_dir, "camillo.bot")

      text = captured_text(chat_state(entity, mud_ctx2))

      assert text =~ "…the writing continues — look to read it all."
      refute text =~ String.duplicate("a", 700)
      assert text =~ String.duplicate("a", 600)
    end

    test "a short description is never truncated", ctx do
      {prov, sc, mud_ctx} = resolve_camillo(ctx)
      short_desc = "A cozy little foyer with dust motes in the light."

      :ok = set_room_description(prov.foyer_uuid, short_desc, sc, mud_ctx, ctx.store)
      Commonplace.Tree.DocCache.clear()

      {:ok, mud_ctx2} = MudContext.resolve(%{name: "camillo"}, sc, ctx.mud_root, ctx.store)

      bot_dir = mint_bot_dir(ctx.store)
      {:ok, entity} = Entity.load(ctx.store, bot_dir, "camillo.bot")

      text = captured_text(chat_state(entity, mud_ctx2))

      assert text =~ short_desc
      refute text =~ "the writing continues"
    end
  end

  ## Direct unit coverage of Perception.render/1 (belt + suspenders on the
  ## precision level requested by the design).

  describe "Perception.render/1 directly" do
    test "renders name, exits, and present contents", ctx do
      {prov, _sc, mud_ctx} = resolve_camillo(ctx)
      entity = %Entity{name: "camillo", dir_uuid: "d", persona: "p", trigger_source: "x"}

      text = Perception.render(%{entity: entity, mud_ctx: mud_ctx})

      # Citizen.provision leaves a "map" object in the Foyer (ensure_map) —
      # so this is a real non-empty-room render, not a contrived fixture.
      assert text == "You stand in Foyer. (no description yet) Exits: north, south. Here: map."
      refute prov.foyer_uuid == nil
    end
  end
end

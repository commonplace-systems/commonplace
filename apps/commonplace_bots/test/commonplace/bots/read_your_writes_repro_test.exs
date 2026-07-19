defmodule Commonplace.Bots.ReadYourWritesReproTest do
  @moduledoc """
  CX-mpk0 (P1, live 2026-07-19) — "move-then-look serves a stale position,"
  fixed by cp-plan ruling #8933/#8934 (UNIFORM option (1)):
  `Commonplace.Bots.Worker.Loop.dispatch_tool/2` now re-reads
  `state.mud_ctx`'s position (`current_room_uuid`/`presence_uuid`) via a
  targeted `Commonplace.MUD.World.find_presence/3` immediately before EVERY
  `Commonplace.Bots.Worker.Tools.dispatch/3` call, not once per turn.

  ## RED-before already established

  These tests were ORIGINALLY written as reproduce-first diagnostics
  (pins (a) and (b) below) against the pre-fix code and FAILED exactly as
  expected — `move` then `look` rendered the room the bot LEFT, and `move`
  then `describe` (default `"here"` target) overwrote that same wrong
  room's description. That failing run IS the RED-before evidence for
  this fix; the assertions below encode the CORRECT behavior throughout
  (never inverted) — they simply failed against the buggy code and pass
  now. Pins (c) and (d) are new, written directly against the fixed
  behavior the GO brief specified.

  ## Why these go through a REAL `Worker.run/4` turn, not `Tools.dispatch/3` directly

  The fix lives INSIDE `Commonplace.Bots.Worker.Loop.dispatch_tool/2` — a
  private function. Calling `Tools.dispatch/3` directly from a test (as an
  earlier draft of this file did) bypasses that refresh entirely and would
  reproduce the pre-fix bug regardless of whether the fix is present or
  not — a false negative waiting to happen. Every pin here drives a real
  `Commonplace.Bots.Worker.run/4` turn with a scripted/stub `client_fn`
  (the SAME dependency-injection seam `worker_test.exs` /
  `transcript_test.exs` / `scrollback_test.exs` use) so the fix's actual
  call site is genuinely exercised.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.Identity, as: BotIdentity
  alias Commonplace.Bots.{Citizen, Entity, MudContext, Worker}
  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Document.ContentType
  alias Commonplace.MUD.World
  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    n = :rand.uniform(1_000_000_000)
    dir = Path.join(System.tmp_dir!(), "cp_bots_rw_repro_#{n}")
    File.mkdir_p!(dir)
    store = :"rw_repro_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"rw_repro_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"rw_repro_tss_#{n}",
       pending_imports_name: :"rw_repro_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    # Move takes green tokens (World.move -> Move.move -> Bursar).
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

    secrets_dir = Path.join(System.tmp_dir!(), "cp_bots_rw_repro_secrets_#{n}")
    File.mkdir_p!(secrets_dir)
    secrets = :"rw_repro_secrets_#{n}"
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

  ## --- Fixtures (mirrors scrollback_test.exs / transcript_test.exs) ---

  defp resolve_camillo(ctx) do
    {:ok, prov} = Citizen.provision("camillo", ctx.mud_root, ctx.store, secret_store: ctx.secrets)

    {:ok, sc} =
      BotIdentity.resolve_signing_context("camillo", ctx.mud_root, ctx.store,
        secret_store: ctx.secrets
      )

    {:ok, mud_ctx} = MudContext.resolve(%{name: "camillo"}, sc, ctx.mud_root, ctx.store)
    {prov, sc, mud_ctx}
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

  # A plain stub client: pops the next canned response off the queue on
  # each call, no side effects, no capture.
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

  # A CAPTURING stub client: forwards every request to the test process
  # (so a test can inspect the assembled tool_result content that fed the
  # NEXT model call) before popping the next canned response.
  defp capturing_stub_client(test_pid, responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn request ->
      send(test_pid, {:request, request})

      case Agent.get_and_update(agent, fn
             [] -> {[], []}
             [h | t] -> {h, t}
           end) do
        [] -> {:error, :stub_exhausted}
        response -> {:ok, response}
      end
    end
  end

  # A SCRIPTED client: each step is `{side_effect_fun/0, response}` — the
  # side effect runs immediately before ITS response is returned (so it
  # lands strictly BEFORE the tool_use in that response gets dispatched —
  # this is how PIN (d) injects an "external actor" move between two tool
  # dispatches inside one turn, something a canned response list alone
  # can't express).
  defp scripted_client(test_pid, steps) do
    {:ok, agent} = Agent.start_link(fn -> steps end)

    fn request ->
      send(test_pid, {:request, request})

      case Agent.get_and_update(agent, fn
             [] -> {:done, []}
             [{side_effect, response} | rest] -> {{:step, side_effect, response}, rest}
           end) do
        :done ->
          {:error, :stub_exhausted}

        {:step, side_effect, response} ->
          side_effect.()
          {:ok, response}
      end
    end
  end

  # Extract a `tool_result` block's `"content"` for `tool_use_id` out of a
  # captured request's message list (the tool_result for tool call N is
  # embedded in the request that ASKS for response N+1).
  defp tool_result_content(request, tool_use_id) do
    request
    |> Map.get(:messages, [])
    |> Enum.find_value(fn msg ->
      msg
      |> Map.get("content", [])
      |> List.wrap()
      |> Enum.find_value(fn
        %{"tool_use_id" => ^tool_use_id, "content" => content} -> content
        _ -> nil
      end)
    end)
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

  ## ---- PIN (b): move -> look renders the DESTINATION (the live symptom) ----

  test "PIN (b): move north then IMMEDIATE look, same turn — look renders the DESTINATION",
       ctx do
    {prov, _sc, _mud_ctx} = resolve_camillo(ctx)
    entity = load_entity(ctx, mint_bot_dir(ctx, ["move", "look"]), "camillo.bot")

    assert {:ok, foyer} = World.get_room(prov.foyer_uuid, ctx.store)
    assert {:ok, study} = World.get_room(prov.study_uuid, ctx.store)
    assert foyer.name != study.name

    test_pid = self()

    responses = [
      tool_use("t1", "move", %{"direction" => "north"}),
      tool_use("t2", "look", %{}),
      end_turn()
    ]

    assert {:ok, :end_turn} =
             Worker.run(
               "jes",
               entity,
               event("explore"),
               worker_opts(ctx, capturing_stub_client(test_pid, responses))
             )

    # GROUND TRUTH (independent of ctx): the schema move DID persist.
    assert {:ok, moved_room_uuid} =
             World.find_presence_room(ctx.mud_root, "camillo.usr", ctx.store)

    assert moved_room_uuid == prov.study_uuid
    refute moved_room_uuid == prov.foyer_uuid

    # THREE client_fn calls happen this turn: the INITIAL request (no tool
    # results yet), the request asking for a response AFTER move's result
    # is in history, and the request asking for a response AFTER look's
    # result is in history — look's (`"t2"`) tool_result only appears in
    # that THIRD captured request.
    assert_receive {:request, _initial}
    assert_receive {:request, _after_move}
    assert_receive {:request, after_look}

    look_text = tool_result_content(after_look, "t2")
    refute is_nil(look_text)

    # THE PIN: look rendered the room the bot is ACTUALLY in, not the one
    # the turn started in.
    assert look_text =~ study.name
    refute look_text =~ foyer.name
  end

  ## ---- PIN (a): THE CORRUPTION PIN (boss-required shape) ----

  test "PIN (a) THE CORRUPTION PIN: move then describe(\"here\") lands the description on the NEW room, old room untouched",
       ctx do
    {prov, _sc, _mud_ctx} = resolve_camillo(ctx)
    entity = load_entity(ctx, mint_bot_dir(ctx, ["move", "describe"]), "camillo.bot")

    responses = [
      tool_use("t1", "move", %{"direction" => "north"}),
      tool_use("t2", "describe", %{"text" => "Freshly distilled memory."}),
      end_turn()
    ]

    assert {:ok, :end_turn} =
             Worker.run(
               "jes",
               entity,
               event("explore then distill"),
               worker_opts(ctx, stub_client(responses))
             )

    assert {:ok, moved_room_uuid} =
             World.find_presence_room(ctx.mud_root, "camillo.usr", ctx.store)

    assert moved_room_uuid == prov.study_uuid

    {:ok, foyer_after} = World.get_room(prov.foyer_uuid, ctx.store)
    {:ok, study_after} = World.get_room(prov.study_uuid, ctx.store)

    # THE CORRUPTION PIN: the NEW room (Study, where the bot actually is)
    # gets the write; the OLD room (Foyer, where the turn started) is
    # byte-untouched. Before the fix this was inverted — the write landed
    # on Foyer, a genuine memory-corruption-class bug, not a mere stale read.
    assert study_after.description == "Freshly distilled memory."
    refute foyer_after.description == "Freshly distilled memory."
  end

  ## ---- PIN (c): move-then-move SUCCEEDS when real exits exist; the
  ## fail-closed guard is PRESERVED for a genuinely-stale source ----

  test "PIN (c) part 1: move-then-move now SUCCEEDS through both hops when exits exist (foyer -> study -> foyer)",
       ctx do
    {prov, _sc, _mud_ctx} = resolve_camillo(ctx)
    entity = load_entity(ctx, mint_bot_dir(ctx, ["move"]), "camillo.bot")

    test_pid = self()

    responses = [
      tool_use("t1", "move", %{"direction" => "north"}),
      tool_use("t2", "move", %{"direction" => "south"}),
      end_turn()
    ]

    assert {:ok, :end_turn} =
             Worker.run(
               "jes",
               entity,
               event("there and back"),
               worker_opts(ctx, capturing_stub_client(test_pid, responses))
             )

    # Hop 1's ("t1") tool_result first appears in the SECOND captured
    # request (the one asking for a response after hop 1's result is in
    # history) — the initial (pre-turn) request has no results yet.
    assert_receive {:request, _initial}
    assert_receive {:request, after_hop1}

    hop1_result = tool_result_content(after_hop1, "t1")
    assert hop1_result =~ "You walk north"

    # Ground truth: back in the Foyer after the round trip.
    assert {:ok, room2} = World.find_presence_room(ctx.mud_root, "camillo.usr", ctx.store)
    assert room2 == prov.foyer_uuid

    # No fork across the round trip: exactly one camillo.usr, anywhere.
    all_camillo_usr =
      World.list_entries(prov.foyer_uuid, ctx.store) ++
        World.list_entries(prov.study_uuid, ctx.store) ++
        World.list_entries(prov.home_room_uuid, ctx.store)

    assert Enum.count(all_camillo_usr, &(&1.name == "camillo.usr")) == 1
  end

  test "PIN (c) part 2: the fail-closed check_still_there guard is PRESERVED for a genuinely-stale source",
       ctx do
    {prov, sc, mud_ctx} = resolve_camillo(ctx)
    entity = load_entity(ctx, mint_bot_dir(ctx, ["move"]), "camillo.bot")

    assert {:ok, :end_turn} =
             Worker.run(
               "jes",
               entity,
               event("go north"),
               worker_opts(
                 ctx,
                 stub_client([tool_use("t1", "move", %{"direction" => "north"}), end_turn()])
               )
             )

    assert {:ok, room} = World.find_presence_room(ctx.mud_root, "camillo.usr", ctx.store)
    assert room == prov.study_uuid

    # With the fix in place, `dispatch_tool/2` refreshes position immediately
    # before every dispatch, so there is no longer a window in the ORDINARY
    # tool-call path for a stale SOURCE to reach `Move.move/5` — that's the
    # whole point of the fix. `check_still_there/3` (the guard
    # `Commonplace.MUD.Move.do_move/5` already had, proven pre-fix to
    # prevent a FORK on a stale source) is a SEPARATE, lower-level safety
    # net, independent of Loop/ctx freshness — call `World.move_presence/5`
    # DIRECTLY (bypassing the tool/dispatch layer entirely) with a
    # deliberately WRONG source (`prov.foyer_uuid`, a room the presence has
    # already left) to prove that net is UNCHANGED/preserved by this fix,
    # not weakened or removed.
    result =
      World.move_presence(
        mud_ctx.presence_uuid,
        "camillo.usr",
        prov.foyer_uuid,
        prov.home_room_uuid,
        store: ctx.store,
        signing_context: sc,
        cert_cids: mud_ctx.cert_cids,
        signer_id: mud_ctx.signer_id,
        viewer: sc.identity_uuid
      )

    assert {:error, _} = result

    # No fork: exactly one camillo.usr, still correctly in the Study.
    all_camillo_usr =
      World.list_entries(prov.foyer_uuid, ctx.store) ++
        World.list_entries(prov.study_uuid, ctx.store) ++
        World.list_entries(prov.home_room_uuid, ctx.store)

    assert Enum.count(all_camillo_usr, &(&1.name == "camillo.usr")) == 1

    assert {:ok, room_uuid} = World.find_presence_room(ctx.mud_root, "camillo.usr", ctx.store)
    assert room_uuid == prov.study_uuid
  end

  ## ---- PIN (d): external-force — heals a position changed by another actor mid-turn ----

  test "PIN (d): a presence moved EXTERNALLY between two tool calls in one turn — the second call acts from the NEW position",
       ctx do
    {prov, sc, mud_ctx} = resolve_camillo(ctx)
    entity = load_entity(ctx, mint_bot_dir(ctx, ["look"]), "camillo.bot")

    test_pid = self()

    external_move = fn ->
      :ok =
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
    end

    noop = fn -> :ok end

    steps = [
      {noop, tool_use("t1", "look", %{})},
      # This runs BEFORE t2's response is handed back — i.e. strictly
      # between look1 being dispatched and look2 being dispatched. The
      # model never called `move`; something else relocated the bot.
      {external_move, tool_use("t2", "look", %{})},
      {noop, end_turn()}
    ]

    assert {:ok, :end_turn} =
             Worker.run(
               "jes",
               entity,
               event("look around"),
               worker_opts(ctx, scripted_client(test_pid, steps))
             )

    assert_receive {:request, _initial}
    assert_receive {:request, after_look1}
    assert_receive {:request, after_look2}

    look1_text = tool_result_content(after_look1, "t1")
    assert look1_text =~ "Foyer"

    look2_text = tool_result_content(after_look2, "t2")

    {:ok, study} = World.get_room(prov.study_uuid, ctx.store)
    {:ok, foyer} = World.get_room(prov.foyer_uuid, ctx.store)

    # THE PIN: the SECOND look, dispatched after the EXTERNAL move, acts
    # from the bot's actual (new) position — even though the model itself
    # never issued a `move` and believed (from look1) it was still in the
    # Foyer.
    assert look2_text =~ study.name
    refute look2_text =~ foyer.name
  end
end

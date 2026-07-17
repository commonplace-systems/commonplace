defmodule Commonplace.MUD.EngineModuleTest do
  @moduledoc """
  CX-2xez (MUD-as-documents Inc-1) — the doc-hosted command parser behind the
  kernel `EngineModule` resolver. Covers the design §5/§7 load-bearing
  properties:

    * doc→run parity + hot-reload (the payoff): a node/trusted-signed parser
      doc compiles and runs; editing it live changes the grammar with no
      restart.
    * NON-BRICK (§5): a broken edit falls back to last-good; a broken-from-
      the-start doc falls back to the compiled-in floor; a compile-OK doc that
      crashes at runtime is contained (try/rescue) — the world keeps parsing.
    * RCE trust-split (§7 W1): a player(non-trusted)-signed edit to the parser
      doc is refused by Gate B (`gate: :execute`) → the resolver keeps the
      trusted last-good; a player cannot inject engine code.
    * manifest trust root (§7 W2): the resolver only ever uses the kernel
      manifest uuid — an arbitrary player-authored "parser" doc is never run.

  Setup mirrors `Commonplace.Code.ExecuteGateTest` (the Gate-B reference).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.Code.SourceDoc
  alias Commonplace.MUD.{EngineModule, Parser}
  alias Commonplace.Store.{CommitStore, CommitStoreClient}

  @store CommitStoreClient

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_engine_mod_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
    {:ok, _pid} = Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    Commonplace.Tree.DocCache.clear()
    SourceDoc.reset_cache()

    # A pinned "trusted" identity — the stand-in for the node/engine authority
    # — and an unpinned "player" identity (the RCE adversary).
    {trusted_pub, trusted_priv} = Signing.generate_keypair()
    trusted_id = "eea11111-0000-0000-0000-#{:rand.uniform(999_999_999_999)}"

    trusted = %SigningContext{
      identity_uuid: trusted_id,
      public_key: trusted_pub,
      private_key: trusted_priv
    }

    {player_pub, player_priv} = Signing.generate_keypair()
    player_id = "b0b22222-0000-0000-0000-#{:rand.uniform(999_999_999_999)}"

    player = %SigningContext{
      identity_uuid: player_id,
      public_key: player_pub,
      private_key: player_priv
    }

    old_manifest = Application.get_env(:commonplace, :mud_engine_manifest)
    old_trust = Application.get_env(:commonplace, :trust)

    on_exit(fn ->
      if is_nil(old_manifest),
        do: Application.delete_env(:commonplace, :mud_engine_manifest),
        else: Application.put_env(:commonplace, :mud_engine_manifest, old_manifest)

      if is_nil(old_trust),
        do: Application.delete_env(:commonplace, :trust),
        else: Application.put_env(:commonplace, :trust, old_trust)

      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")

      {:ok, _pid} =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"})

      Commonplace.Tree.DocCache.clear()
      SourceDoc.reset_cache()
      File.rm_rf!(dir)
    end)

    %{trusted: trusted, trusted_id: trusted_id, trusted_pub: trusted_pub, player: player}
  end

  # --- helpers ---

  defp permissive!,
    do:
      Application.put_env(:commonplace, :trust, %{accept_unsigned: true, trusted_identities: %{}})

  defp strict!(trusted),
    do:
      Application.put_env(:commonplace, :trust, %{
        accept_unsigned: false,
        trusted_identities: trusted
      })

  defp set_manifest(uuid),
    do: Application.put_env(:commonplace, :mud_engine_manifest, %{parser: uuid})

  defp clear_manifest, do: Application.put_env(:commonplace, :mud_engine_manifest, %{})

  # A valid doc-hosted parser. `extra` injects extra verb aliases (for the
  # hot-reload test). Behaviour mirrors the compiled-in Parser floor.
  defp parser_source(extra \\ "") do
    ~s'''
    defmodule Commonplace.MUD.EngineParser do
      @aliases Map.merge(%{"n" => "north", "l" => "look", "i" => "inventory"}, %{#{extra}})
      def parse(line) when is_binary(line) do
        line = String.trim(line)
        case line do
          "" -> %Commonplace.MUD.Parser.Command{}
          _ ->
            [w | _] = String.split(line, ~r/\s+/, trim: true)
            {verb_word, args} =
              case String.split(line, ~r/\s+/, parts: 2) do
                [v] -> {v, ""}
                [v, rest] -> {v, rest}
              end
            verb = Map.get(@aliases, String.downcase(verb_word), String.downcase(verb_word))
            argv = if args == "", do: [], else: String.split(args, ~r/\s+/, trim: true)
            _ = w
            %Commonplace.MUD.Parser.Command{verb: verb, args: args, argv: argv, target: List.first(argv)}
        end
      end
    end
    '''
  end

  defp crashing_source do
    ~s'''
    defmodule Commonplace.MUD.EngineParser do
      def parse(_line), do: raise("boom from a doc-hosted parser")
    end
    '''
  end

  defp broken_source, do: "defmodule Commonplace.MUD.EngineParser do  def parse(  # unbalanced\n"

  defp content_update(source) do
    Yelixer.Doc.new()
    |> ContentType.create(:text, "_engine_parser.ex")
    |> ContentType.insert_text(0, source)
    |> Yelixer.Encoding.encode_update()
  end

  defp mint(source, opts) do
    uuid = UUID.uuid4()

    CommitStore.create_chained_commit(
      CommitStore,
      uuid,
      content_update(source),
      %{kind: :regular},
      opts
    )

    uuid
  end

  defp edit(uuid, source, opts) do
    CommitStore.create_chained_commit(
      CommitStore,
      uuid,
      content_update(source),
      %{kind: :regular},
      opts
    )

    SourceDoc.reset_cache()
    :ok
  end

  defp attach_fallback_alarm do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      {:engine_fallback, ref},
      [:commonplace, :mud, :engine_module, :fallback],
      fn _e, _m, meta, _c -> send(parent, {:engine_fallback, ref, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({:engine_fallback, ref}) end)
    ref
  end

  # --- doc→run parity + floor ---

  test "doc→run: a trusted parser doc parses in parity with the compiled-in floor" do
    permissive!()
    uuid = mint(parser_source(), [])
    set_manifest(uuid)

    for line <- ["take orrery", "n", "look at the wall", "l", "", "  say hi  "] do
      assert EngineModule.parse(line, @store) == Parser.parse(line),
             "doc-hosted parse of #{inspect(line)} must match the floor"
    end
  end

  test "no manifest entry → the compiled-in floor parses (silently, no alarm)" do
    permissive!()
    clear_manifest()
    ref = attach_fallback_alarm()

    assert EngineModule.parse("take orrery", @store) == Parser.parse("take orrery")
    refute_receive {:engine_fallback, ^ref, _}, 100
  end

  # --- hot-reload (the payoff) ---

  test "hot-reload: editing the parser doc adds a live alias with no restart" do
    permissive!()
    uuid = mint(parser_source(), [])
    set_manifest(uuid)

    # Before: "grab" is an unknown verb (no alias).
    assert %Parser.Command{verb: "grab"} = EngineModule.parse("grab orrery", @store)

    # Edit the doc: add "grab" → "take".
    :ok = edit(uuid, parser_source(~s("grab" => "take")), [])

    # After: the next parse reflects the new grammar — no redeploy.
    assert %Parser.Command{verb: "take", target: "orrery"} =
             EngineModule.parse("grab orrery", @store)
  end

  # --- NON-BRICK tier 1: last-good ---

  test "non-brick: a broken EDIT falls back to last-good; the world keeps parsing + alarms" do
    permissive!()
    ref = attach_fallback_alarm()
    uuid = mint(parser_source(), [])
    set_manifest(uuid)

    # A good compile first (establishes last-good).
    assert %Parser.Command{verb: "take"} = EngineModule.parse("take orrery", @store)

    # Now a broken edit (won't compile).
    :ok = edit(uuid, broken_source(), [])

    # Non-vacuous: drive a real command → still a correct %Command{} (last-good),
    # and the fallback alarm fired.
    assert %Parser.Command{verb: "take", target: "orrery"} =
             EngineModule.parse("take orrery", @store)

    assert_receive {:engine_fallback, ^ref, %{name: :parser}}, 500
  end

  # --- NON-BRICK tier 2: compiled-in floor (broken from the start) ---

  test "non-brick: a broken-FROM-THE-START doc (never compiled) falls back to the floor" do
    permissive!()
    ref = attach_fallback_alarm()
    uuid = mint(broken_source(), [])
    set_manifest(uuid)

    # No doc version ever compiled → the compiled-in floor parses correctly.
    assert EngineModule.parse("take orrery", @store) == Parser.parse("take orrery")
    assert_receive {:engine_fallback, ^ref, _}, 500
  end

  # --- NON-BRICK tier 3: runtime-crash containment ---

  test "non-brick: a doc that COMPILES but crashes at runtime is contained → floor" do
    permissive!()
    ref = attach_fallback_alarm()
    uuid = mint(crashing_source(), [])
    set_manifest(uuid)

    # The doc-module compiles (resolve returns it) but parse/1 raises; the
    # try/rescue contains it and the floor produces a correct %Command{}.
    assert EngineModule.parse("take orrery", @store) == Parser.parse("take orrery")
    assert_receive {:engine_fallback, ^ref, _}, 500
  end

  # --- RCE trust-split (§7 W1) ---

  test "RCE guard: a player-signed edit to the parser doc is REFUSED (Gate B) → trusted last-good survives",
       %{trusted: trusted, trusted_id: trusted_id, trusted_pub: trusted_pub, player: player} do
    strict!(%{trusted_id => Signing.encode_key(trusted_pub)})

    # Trusted genesis compiles + runs (establishes last-good).
    uuid = mint(parser_source(), signing_context: trusted)
    set_manifest(uuid)
    assert %Parser.Command{verb: "take"} = EngineModule.parse("take orrery", @store)

    ref = attach_fallback_alarm()

    # The adversary edits the parser doc to inject a NEW grammar (signed by an
    # untrusted player identity). Under strict Gate B, the compile is refused.
    :ok = edit(uuid, parser_source(~s("pwn" => "hacked")), signing_context: player)

    # Direct proof the compile is denied:
    assert {:error, {:execution_denied, _}} = SourceDoc.compile(uuid, @store, gate: :execute)

    # And the resolver serves the trusted compiled-in FLOOR on the authority
    # failure (CX-aya0 revocation fix: an {:execution_denied} = revoked/tainted
    # authority never serves a cached artifact) — the injected grammar never runs
    # ("pwn" is NOT aliased to "hacked"; it parses as the literal verb). Here the
    # floor is byte-identical to the trusted genesis, so this is indistinguishable
    # from last-good; the divergent-doc test below pins that it's the FLOOR.
    assert %Parser.Command{verb: "pwn"} = EngineModule.parse("pwn orrery", @store)

    assert %Parser.Command{verb: "take", target: "orrery"} =
             EngineModule.parse("take orrery", @store)

    assert_receive {:engine_fallback, ^ref, %{name: :parser}}, 500
  end

  # --- manifest trust root (§7 W2) ---

  test "manifest trust root: a player-authored parser doc NOT in the manifest is never resolved",
       %{player: player} do
    permissive!()

    # A player authors their own perfectly-compilable "parser" doc that would
    # alias "take" → something malicious — but it is NOT in the manifest.
    _player_uuid = mint(parser_source(~s("take" => "PLAYER_HIJACK")), signing_context: player)

    # Manifest empty → the resolver uses the floor, never the player's doc.
    clear_manifest()
    assert %Parser.Command{verb: "take"} = EngineModule.parse("take orrery", @store)
    refute EngineModule.parse("take orrery", @store).verb == "PLAYER_HIJACK"
  end

  # --- Bootstrap seed integration (the real node-signed seed) ---

  test "Bootstrap.ensure_engine_parser seeds a node-signed parser doc that parses in parity" do
    permissive!()
    assert :ok = Commonplace.MUD.Bootstrap.ensure_engine_parser(@store)

    # The manifest is now pointed at the seeded doc; parse routes through it.
    for line <- ["take orrery", "n", "'hello there", "look", "inv"] do
      assert EngineModule.parse(line, @store) == Parser.parse(line),
             "seeded doc-hosted parse of #{inspect(line)} must match the floor"
    end
  end

  # --- CX-aya0 (MUD-as-documents Inc-2 / B1): the doc-hosted `look` verb ---
  #
  # `run_verb/4` is the verb-shaped sibling of `parse/2` exercised above —
  # same manifest/Gate-B/tiered-fallback mechanism, applied to
  # `Commonplace.MUD.Verbs`'s FIRST doc-hosted verb. These tests cover the
  # same load-bearing properties (doc->run parity, non-brick tiers 1-3, the
  # RCE trust-split, the manifest trust root) for the verb path, plus the
  # live Bootstrap seed integration.
  describe "look verb (Inc-2 / B1)" do
    alias Commonplace.MUD.Schemas
    alias Commonplace.MUD.Schemas.Room
    alias Commonplace.MUD.Verbs.LookFloor
    alias Commonplace.Tree.Schema

    # A minimal but real ctx: a seeded room (readable via World.room_snapshot)
    # + a seeded player dir (readable via Schemas.load_player), same shape
    # PlayerSession builds (see player_session.ex's ctx map), just hand-built
    # here so this test doesn't need a full PlayerSession/PubSub stack.
    defp build_ctx do
      root_uuid = UUID.uuid4()
      root_update = Yelixer.Encoding.encode_update(Schema.new_schema())
      CommitStore.create_commit(CommitStore, root_uuid, root_update, nil)

      {:ok, room_uuid} =
        Schemas.create_dir_with_meta(
          Schemas.room_filename(),
          Schemas.encode_room(%Room{name: "The Vault", description: "A quiet stone vault."}),
          @store
        )

      {:ok, player_uuid} =
        Schemas.create_dir_with_meta(
          Schemas.player_filename(),
          Schemas.encode_player(%Schemas.Player{
            name: "alice",
            description: "A curious adventurer."
          }),
          @store
        )

      %{
        player_name: "alice",
        player_dir_uuid: player_uuid,
        # No separate inventory dir needed for these pure look tests — reuse
        # the player dir (an empty, real, readable dir schema either way).
        inventory_uuid: player_uuid,
        current_room_uuid: room_uuid,
        presence_filename: "alice.usr",
        store: @store,
        signing_context: nil
      }
    end

    defp look_cmd(argv \\ [], target \\ nil),
      do: %Parser.Command{verb: "look", argv: argv, target: target || List.first(argv)}

    defp look_source(extra_clause \\ "") do
      ~s'''
      defmodule Commonplace.MUD.EngineLook do
        alias Commonplace.MUD.Schemas
        alias Commonplace.MUD.Schemas.Player
        alias Commonplace.MUD.World

        #{extra_clause}

        def run(%Commonplace.MUD.Parser.Command{argv: []}, ctx), do: {:reply, render_room(ctx)}

        def run(%Commonplace.MUD.Parser.Command{target: target}, ctx) when target in ["here", "room"] do
          {:reply, render_room(ctx)}
        end

        def run(%Commonplace.MUD.Parser.Command{target: target}, ctx) when target in ["me", "self", "myself"] do
          case Schemas.load_player(ctx.player_dir_uuid, ctx.store) do
            {:ok, %Player{} = pl} ->
              title = if pl.title == "", do: pl.name, else: pl.title
              {:reply, "\#{title}\\n\#{pl.description}"}

            _ ->
              {:reply, ctx.player_name}
          end
        end

        defp render_room(ctx) do
          case World.room_snapshot(ctx.current_room_uuid, ctx.presence_filename, ctx.store, []) do
            {:ok, %{name: name, desc: desc}} -> "== \#{name} ==\\n\#{desc}\\n"
            _ -> "(this place has no description)"
          end
        end
      end
      '''
    end

    defp crashing_look_source do
      ~s'''
      defmodule Commonplace.MUD.EngineLook do
        def run(_cmd, _ctx), do: raise("boom from a doc-hosted look verb")
      end
      '''
    end

    defp look_content_update(source) do
      Yelixer.Doc.new()
      |> ContentType.create(:text, "_engine_look.ex")
      |> ContentType.insert_text(0, source)
      |> Yelixer.Encoding.encode_update()
    end

    defp mint_look(source, opts) do
      uuid = UUID.uuid4()

      CommitStore.create_chained_commit(
        CommitStore,
        uuid,
        look_content_update(source),
        %{kind: :regular},
        opts
      )

      uuid
    end

    defp edit_look(uuid, source, opts) do
      CommitStore.create_chained_commit(
        CommitStore,
        uuid,
        look_content_update(source),
        %{kind: :regular},
        opts
      )

      SourceDoc.reset_cache()
      :ok
    end

    defp set_look_manifest(uuid) do
      manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})
      Application.put_env(:commonplace, :mud_engine_manifest, Map.put(manifest, :look, uuid))
    end

    # The manifest is GLOBAL app-env (a trust root, node-set) — the running
    # app boot (and Bootstrap.ensure_engine_look_verb) leaves a `:look`
    # entry in it, so the "no manifest entry" tests must DELETE :look
    # explicitly rather than assume it's absent (the parser tests clear the
    # whole manifest via clear_manifest/0 for the same reason).
    defp clear_look_manifest do
      manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})
      Application.put_env(:commonplace, :mud_engine_manifest, Map.delete(manifest, :look))
    end

    test "no manifest entry -> the compiled-in floor runs (silently, no alarm)" do
      permissive!()
      clear_look_manifest()
      ctx = build_ctx()
      ref = attach_fallback_alarm()

      assert {:reply, text} = EngineModule.run_verb(:look, look_cmd(), ctx, @store)
      assert {:reply, text} == LookFloor.run(look_cmd(), ctx)
      refute_receive {:engine_fallback, ^ref, _}, 100
    end

    test "doc->run: a trusted look doc runs bare `look` end-to-end via SourceDoc.compile + Gate B" do
      permissive!()
      ctx = build_ctx()
      uuid = mint_look(look_source(), [])
      set_look_manifest(uuid)

      # Direct proof the doc actually compiled + ran (not silently on the floor):
      assert {:ok, _module} = SourceDoc.compile(uuid, @store, gate: :execute)

      assert {:reply, text} = EngineModule.run_verb(:look, look_cmd(), ctx, @store)
      assert text =~ "The Vault"
      assert text =~ "A quiet stone vault."
      assert {:reply, ^text} = EngineModule.run_verb(:look, look_cmd(), ctx, @store)
    end

    test "doc->run: `look me` runs through the doc-hosted module too" do
      permissive!()
      ctx = build_ctx()
      uuid = mint_look(look_source(), [])
      set_look_manifest(uuid)

      assert {:reply, text} = EngineModule.run_verb(:look, look_cmd(["me"]), ctx, @store)
      assert text == "alice\nA curious adventurer."
    end

    test "hot-reload: editing the look doc changes the rendered room with no restart" do
      permissive!()
      ctx = build_ctx()
      uuid = mint_look(look_source(), [])
      set_look_manifest(uuid)

      assert {:reply, before_text} = EngineModule.run_verb(:look, look_cmd(), ctx, @store)
      assert before_text =~ "The Vault"

      :ok =
        edit_look(
          uuid,
          look_source() |> String.replace("== \#{name} ==", "*** \#{name} ***"),
          []
        )

      assert {:reply, after_text} = EngineModule.run_verb(:look, look_cmd(), ctx, @store)
      assert after_text =~ "*** The Vault ***"
    end

    test "non-brick: a broken EDIT falls back to last-good; the world keeps rendering + alarms" do
      permissive!()
      ctx = build_ctx()
      ref = attach_fallback_alarm()
      uuid = mint_look(look_source(), [])
      set_look_manifest(uuid)

      assert {:reply, good_text} = EngineModule.run_verb(:look, look_cmd(), ctx, @store)
      assert good_text =~ "The Vault"

      :ok = edit_look(uuid, broken_source(), [])

      assert {:reply, ^good_text} = EngineModule.run_verb(:look, look_cmd(), ctx, @store)
      assert_receive {:engine_fallback, ^ref, %{name: :look}}, 500
    end

    test "non-brick: a broken-FROM-THE-START look doc falls back to the compiled-in floor" do
      permissive!()
      ctx = build_ctx()
      ref = attach_fallback_alarm()
      uuid = mint_look(broken_source(), [])
      set_look_manifest(uuid)

      assert {:reply, text} = EngineModule.run_verb(:look, look_cmd(), ctx, @store)
      assert {:reply, text} == LookFloor.run(look_cmd(), ctx)
      assert_receive {:engine_fallback, ^ref, _}, 500
    end

    test "non-brick: a look doc that COMPILES but crashes at runtime is contained -> floor" do
      permissive!()
      ctx = build_ctx()
      ref = attach_fallback_alarm()
      uuid = mint_look(crashing_look_source(), [])
      set_look_manifest(uuid)

      assert {:reply, text} = EngineModule.run_verb(:look, look_cmd(), ctx, @store)
      assert {:reply, text} == LookFloor.run(look_cmd(), ctx)
      assert_receive {:engine_fallback, ^ref, _}, 500
    end

    test "non-brick: an UNIMPLEMENTED subcommand in a partial doc raises FunctionClauseError -> floor" do
      # Exercises the deliberate partial-coverage design (Bootstrap's seeded
      # look doc only implements bare/here/me) — `look <object>` has no
      # matching clause in `look_source/1`, so it falls back per-call.
      permissive!()
      ctx = build_ctx()
      ref = attach_fallback_alarm()
      uuid = mint_look(look_source(), [])
      set_look_manifest(uuid)

      cmd = look_cmd(["orrery"])
      assert EngineModule.run_verb(:look, cmd, ctx, @store) == LookFloor.run(cmd, ctx)
      assert_receive {:engine_fallback, ^ref, _}, 500
    end

    test "RCE guard: a player-signed edit to the look doc is REFUSED (Gate B) -> trusted last-good survives",
         %{trusted: trusted, trusted_id: trusted_id, trusted_pub: trusted_pub, player: player} do
      strict!(%{trusted_id => Signing.encode_key(trusted_pub)})
      ctx = build_ctx()

      uuid = mint_look(look_source(), signing_context: trusted)
      set_look_manifest(uuid)
      assert {:reply, trusted_text} = EngineModule.run_verb(:look, look_cmd(), ctx, @store)
      assert trusted_text =~ "The Vault"

      ref = attach_fallback_alarm()

      # A player-signed edit tries to inject a rendering that leaks something
      # the trusted doc never would (e.g. tampering with the header).
      :ok =
        edit_look(
          uuid,
          look_source() |> String.replace("== \#{name} ==", "PWNED \#{name}"),
          signing_context: player
        )

      assert {:error, {:execution_denied, _}} = SourceDoc.compile(uuid, @store, gate: :execute)

      # The resolver serves the trusted compiled-in FLOOR on the authority failure
      # (CX-aya0 revocation fix) — the injected render never runs. (This test's
      # hand-written trusted doc uses a SIMPLIFIED render, so the floor differs
      # from trusted_text — a direct demonstration that the FLOOR, not the cached
      # last-good, is served; the divergent-doc test below pins it explicitly.)
      assert {:reply, floor_text} = EngineModule.run_verb(:look, look_cmd(), ctx, @store)
      assert {:reply, floor_text} == LookFloor.run(look_cmd(), ctx)
      refute floor_text =~ "PWNED"
      assert_receive {:engine_fallback, ^ref, %{name: :look}}, 500
    end

    test "revocation fix: on an AUTHORITY failure the resolver serves the FLOOR, NOT the (now-untrusted) last-good",
         %{trusted: trusted, trusted_id: trusted_id, trusted_pub: trusted_pub, player: player} do
      # The load-bearing pin for CX-aya0 (plan #7255/#7257): make last-good
      # DIVERGE from the floor (a trusted ENHANCED doc handling `look secret`),
      # then trigger an authority failure. Old behavior served the cached
      # (enhanced) last-good = the cache-defeats-revocation hole; the fix serves
      # the FLOOR. Uses a player-signed edit to produce the {:execution_denied}
      # authority failure — the SAME branch a revocation takes (both fail Gate B),
      # so this pins the revocation case via the shared authority-failure path.
      strict!(%{trusted_id => Signing.encode_key(trusted_pub)})
      ctx = build_ctx()

      enhanced =
        ~s|def run(%Commonplace.MUD.Parser.Command{target: "secret"}, _ctx), do: {:reply, "ENHANCED-SECRET-42"}|

      uuid = mint_look(look_source(enhanced), signing_context: trusted)
      set_look_manifest(uuid)

      # last-good is the ENHANCED doc — it answers `look secret` (the floor does NOT)
      assert {:reply, "ENHANCED-SECRET-42"} =
               EngineModule.run_verb(:look, look_cmd(["secret"]), ctx, @store)

      ref = attach_fallback_alarm()

      # authority failure: a player-signed edit → Gate B denies (same tag a
      # revocation of the doc's execute authority would produce)
      :ok = edit_look(uuid, look_source(enhanced), signing_context: player)
      assert {:error, {:execution_denied, _}} = SourceDoc.compile(uuid, @store, gate: :execute)

      # THE FIX: the enhanced last-good is NOT served — the FLOOR is. `look secret`
      # no longer returns the enhanced answer; it matches the compiled-in floor.
      result = EngineModule.run_verb(:look, look_cmd(["secret"]), ctx, @store)
      refute match?({:reply, "ENHANCED-SECRET-42"}, result)
      assert result == LookFloor.run(look_cmd(["secret"]), ctx)
      assert_receive {:engine_fallback, ^ref, %{name: :look}}, 500
    end

    test "manifest trust root: a player-authored look doc NOT in the manifest is never resolved",
         %{player: player} do
      permissive!()
      clear_look_manifest()
      ctx = build_ctx()

      _player_uuid =
        mint_look(
          look_source() |> String.replace("== \#{name} ==", "HIJACKED \#{name}"),
          signing_context: player
        )

      # Manifest has no :look entry -> the resolver uses the floor.
      assert {:reply, text} = EngineModule.run_verb(:look, look_cmd(), ctx, @store)
      assert {:reply, text} == LookFloor.run(look_cmd(), ctx)
      refute text =~ "HIJACKED"
    end

    test "Bootstrap.ensure_engine_look_verb seeds a node-signed look doc that runs in parity with the floor" do
      permissive!()
      ctx = build_ctx()

      assert :ok = Commonplace.MUD.Bootstrap.ensure_engine_look_verb(@store)

      for cmd <- [look_cmd(), look_cmd(["me"])] do
        assert EngineModule.run_verb(:look, cmd, ctx, @store) == LookFloor.run(cmd, ctx),
               "seeded doc-hosted look of #{inspect(cmd)} must match the floor"
      end
    end
  end

  # ---- CX-aya0 (MUD-as-documents Inc-2 / B2): the doc-hosted `inventory` verb ----
  #
  # Same `run_verb/4` mechanism as `look` (B1) above, applied to the next
  # stateless-leaf verb: `inventory` is a PURE read + format (zero tree
  # writes — see `do_inventory/1`). Mirrors the B1 test shape exactly.

  describe "inventory verb (Inc-2 / B2)" do
    alias Commonplace.MUD.Schemas
    alias Commonplace.MUD.Schemas.Object
    alias Commonplace.MUD.Verbs.InventoryFloor
    alias Commonplace.Tree.Schema

    defp build_inventory_ctx(item_names \\ ["widget"]) do
      root_uuid = UUID.uuid4()
      root_update = Yelixer.Encoding.encode_update(Schema.new_schema())
      CommitStore.create_commit(CommitStore, root_uuid, root_update, nil)

      {:ok, inventory_uuid} = Schemas.create_dir_with_meta(nil, nil, @store)

      for name <- item_names do
        {:ok, obj_uuid} =
          Schemas.create_dir_with_meta(
            Schemas.object_filename(),
            Schemas.encode_object(%Object{name: name}),
            @store
          )

        {:ok, schema} = Schemas.load_dir_schema(inventory_uuid, @store)
        schema = Schema.add_directory(schema, "#{name}.obj", obj_uuid)
        update = Yelixer.Encoding.encode_update(schema)

        CommitStore.create_chained_commit(
          CommitStore,
          inventory_uuid,
          update,
          %{kind: :regular},
          []
        )
      end

      %{
        player_name: "alice",
        inventory_uuid: inventory_uuid,
        store: @store,
        signing_context: nil
      }
    end

    defp inventory_cmd, do: %Parser.Command{verb: "inventory", argv: [], target: nil}

    defp inventory_source do
      ~s'''
      defmodule Commonplace.MUD.EngineInventory do
        alias Commonplace.MUD.Schemas
        alias Commonplace.MUD.Schemas.Object
        alias Commonplace.MUD.World

        def run(_cmd, ctx) do
          items =
            World.list_objects_in(ctx.inventory_uuid, ctx.store)
            |> Enum.map(fn e ->
              case Schemas.load_object(e.node_id, ctx.store) do
                {:ok, %Object{name: name}} -> name
                _ -> e.name
              end
            end)

          text =
            case items do
              [] -> "You are carrying nothing."
              _ -> "You are carrying:\\n  - " <> Enum.join(items, "\\n  - ")
            end

          {:reply, text}
        end
      end
      '''
    end

    defp crashing_inventory_source do
      ~s'''
      defmodule Commonplace.MUD.EngineInventory do
        def run(_cmd, _ctx), do: raise("boom from a doc-hosted inventory verb")
      end
      '''
    end

    defp inventory_content_update(source) do
      Yelixer.Doc.new()
      |> ContentType.create(:text, "_engine_inventory.ex")
      |> ContentType.insert_text(0, source)
      |> Yelixer.Encoding.encode_update()
    end

    defp mint_inventory(source, opts) do
      uuid = UUID.uuid4()

      CommitStore.create_chained_commit(
        CommitStore,
        uuid,
        inventory_content_update(source),
        %{kind: :regular},
        opts
      )

      uuid
    end

    defp edit_inventory(uuid, source, opts) do
      CommitStore.create_chained_commit(
        CommitStore,
        uuid,
        inventory_content_update(source),
        %{kind: :regular},
        opts
      )

      SourceDoc.reset_cache()
      :ok
    end

    defp set_inventory_manifest(uuid) do
      manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})
      Application.put_env(:commonplace, :mud_engine_manifest, Map.put(manifest, :inventory, uuid))
    end

    defp clear_inventory_manifest do
      manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})
      Application.put_env(:commonplace, :mud_engine_manifest, Map.delete(manifest, :inventory))
    end

    test "no manifest entry -> the compiled-in floor runs (silently, no alarm)" do
      permissive!()
      clear_inventory_manifest()
      ctx = build_inventory_ctx()
      ref = attach_fallback_alarm()

      assert {:reply, text} = EngineModule.run_verb(:inventory, inventory_cmd(), ctx, @store)
      assert {:reply, text} == InventoryFloor.run(inventory_cmd(), ctx)
      refute_receive {:engine_fallback, ^ref, _}, 100
    end

    test "doc->run: a trusted inventory doc lists carried items end-to-end via SourceDoc.compile + Gate B" do
      permissive!()
      ctx = build_inventory_ctx(["widget", "orrery"])
      uuid = mint_inventory(inventory_source(), [])
      set_inventory_manifest(uuid)

      assert {:ok, _module} = SourceDoc.compile(uuid, @store, gate: :execute)

      assert {:reply, text} = EngineModule.run_verb(:inventory, inventory_cmd(), ctx, @store)
      assert text =~ "widget"
      assert text =~ "orrery"
    end

    test "hot-reload: editing the inventory doc changes the rendered listing with no restart" do
      permissive!()
      ctx = build_inventory_ctx(["widget"])
      uuid = mint_inventory(inventory_source(), [])
      set_inventory_manifest(uuid)

      assert {:reply, before_text} =
               EngineModule.run_verb(:inventory, inventory_cmd(), ctx, @store)

      assert before_text =~ "You are carrying:"

      :ok =
        edit_inventory(
          uuid,
          inventory_source() |> String.replace("You are carrying:", "You clutch:"),
          []
        )

      assert {:reply, after_text} =
               EngineModule.run_verb(:inventory, inventory_cmd(), ctx, @store)

      assert after_text =~ "You clutch:"
    end

    test "non-brick: a broken EDIT falls back to last-good; the world keeps rendering + alarms" do
      permissive!()
      ctx = build_inventory_ctx(["widget"])
      ref = attach_fallback_alarm()
      uuid = mint_inventory(inventory_source(), [])
      set_inventory_manifest(uuid)

      assert {:reply, good_text} = EngineModule.run_verb(:inventory, inventory_cmd(), ctx, @store)

      :ok = edit_inventory(uuid, broken_source(), [])

      assert {:reply, ^good_text} =
               EngineModule.run_verb(:inventory, inventory_cmd(), ctx, @store)

      assert_receive {:engine_fallback, ^ref, %{name: :inventory}}, 500
    end

    test "non-brick: a broken-FROM-THE-START inventory doc falls back to the compiled-in floor" do
      permissive!()
      ctx = build_inventory_ctx(["widget"])
      ref = attach_fallback_alarm()
      uuid = mint_inventory(broken_source(), [])
      set_inventory_manifest(uuid)

      assert {:reply, text} = EngineModule.run_verb(:inventory, inventory_cmd(), ctx, @store)
      assert {:reply, text} == InventoryFloor.run(inventory_cmd(), ctx)
      assert_receive {:engine_fallback, ^ref, _}, 500
    end

    test "non-brick: an inventory doc that COMPILES but crashes at runtime is contained -> floor" do
      permissive!()
      ctx = build_inventory_ctx(["widget"])
      ref = attach_fallback_alarm()
      uuid = mint_inventory(crashing_inventory_source(), [])
      set_inventory_manifest(uuid)

      assert {:reply, text} = EngineModule.run_verb(:inventory, inventory_cmd(), ctx, @store)
      assert {:reply, text} == InventoryFloor.run(inventory_cmd(), ctx)
      assert_receive {:engine_fallback, ^ref, _}, 500
    end

    test "RCE guard: a player-signed edit to the inventory doc is REFUSED (Gate B) -> trusted last-good survives",
         %{trusted: trusted, trusted_id: trusted_id, trusted_pub: trusted_pub, player: player} do
      strict!(%{trusted_id => Signing.encode_key(trusted_pub)})
      ctx = build_inventory_ctx(["widget"])

      uuid = mint_inventory(inventory_source(), signing_context: trusted)
      set_inventory_manifest(uuid)

      assert {:reply, trusted_text} =
               EngineModule.run_verb(:inventory, inventory_cmd(), ctx, @store)

      assert trusted_text =~ "widget"

      ref = attach_fallback_alarm()

      :ok =
        edit_inventory(
          uuid,
          inventory_source() |> String.replace("You are carrying:", "PWNED"),
          signing_context: player
        )

      assert {:error, {:execution_denied, _}} = SourceDoc.compile(uuid, @store, gate: :execute)

      # revocation-safety invariant (CX-aya0): the resolver serves the FLOOR on
      # an authority failure, NEVER the (now-untrusted) cached last-good.
      assert {:reply, floor_text} =
               EngineModule.run_verb(:inventory, inventory_cmd(), ctx, @store)

      assert {:reply, floor_text} == InventoryFloor.run(inventory_cmd(), ctx)
      refute floor_text =~ "PWNED"
      assert_receive {:engine_fallback, ^ref, %{name: :inventory}}, 500
    end

    test "manifest trust root: a player-authored inventory doc NOT in the manifest is never resolved",
         %{player: player} do
      permissive!()
      clear_inventory_manifest()
      ctx = build_inventory_ctx(["widget"])

      _player_uuid =
        mint_inventory(
          inventory_source() |> String.replace("You are carrying:", "HIJACKED"),
          signing_context: player
        )

      assert {:reply, text} = EngineModule.run_verb(:inventory, inventory_cmd(), ctx, @store)
      assert {:reply, text} == InventoryFloor.run(inventory_cmd(), ctx)
      refute text =~ "HIJACKED"
    end

    test "Bootstrap.ensure_engine_inventory_verb seeds a node-signed inventory doc that runs in parity with the floor" do
      permissive!()
      ctx = build_inventory_ctx(["widget", "orrery"])

      assert :ok = Commonplace.MUD.Bootstrap.ensure_engine_inventory_verb(@store)

      assert EngineModule.run_verb(:inventory, inventory_cmd(), ctx, @store) ==
               InventoryFloor.run(inventory_cmd(), ctx)
    end
  end

  # ---- CX-aya0 (MUD-as-documents Inc-2 / B2): the doc-hosted `say`/`emote` verbs ----
  #
  # Same `run_verb/4` mechanism as `look`/`inventory` above. `say`/`emote`
  # are PURE `World.broadcast_room` PubSub broadcasts (zero tree writes —
  # see `do_say/2`/`do_emote/2`), so their ctx just needs a room uuid + a
  # subscriber to observe the broadcast payload.

  describe "say/emote verbs (Inc-2 / B2)" do
    alias Commonplace.MUD.Topics
    alias Commonplace.MUD.Verbs.{EmoteFloor, SayFloor}

    setup do
      Application.ensure_all_started(:phoenix_pubsub)

      case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      :ok
    end

    defp build_say_ctx do
      %{
        player_name: "alice",
        current_room_uuid: UUID.uuid4(),
        store: @store,
        signing_context: nil
      }
    end

    defp say_cmd(text),
      do: %Parser.Command{verb: "say", args: text, argv: String.split(text), target: nil}

    defp emote_cmd(text),
      do: %Parser.Command{verb: "emote", args: text, argv: String.split(text), target: nil}

    defp say_source do
      ~s'''
      defmodule Commonplace.MUD.EngineSay do
        alias Commonplace.MUD.World

        def run(%Commonplace.MUD.Parser.Command{args: ""}, _ctx), do: {:error, "Say what?"}

        def run(%Commonplace.MUD.Parser.Command{args: text}, ctx) do
          World.broadcast_room(ctx.current_room_uuid, %{kind: :say, who: ctx.player_name, text: text})
          :ok
        end
      end
      '''
    end

    defp emote_source do
      ~s'''
      defmodule Commonplace.MUD.EngineEmote do
        alias Commonplace.MUD.World

        def run(%Commonplace.MUD.Parser.Command{args: ""}, _ctx), do: {:error, "Emote what?"}

        def run(%Commonplace.MUD.Parser.Command{args: text}, ctx) do
          World.broadcast_room(ctx.current_room_uuid, %{kind: :emote, who: ctx.player_name, text: text})
          :ok
        end
      end
      '''
    end

    defp crashing_say_source do
      ~s'''
      defmodule Commonplace.MUD.EngineSay do
        def run(_cmd, _ctx), do: raise("boom from a doc-hosted say verb")
      end
      '''
    end

    defp say_content_update(source, filename) do
      Yelixer.Doc.new()
      |> ContentType.create(:text, filename)
      |> ContentType.insert_text(0, source)
      |> Yelixer.Encoding.encode_update()
    end

    defp mint_say(source, opts, filename \\ "_engine_say.ex") do
      uuid = UUID.uuid4()

      CommitStore.create_chained_commit(
        CommitStore,
        uuid,
        say_content_update(source, filename),
        %{kind: :regular},
        opts
      )

      uuid
    end

    defp edit_say(uuid, source, opts, filename \\ "_engine_say.ex") do
      CommitStore.create_chained_commit(
        CommitStore,
        uuid,
        say_content_update(source, filename),
        %{kind: :regular},
        opts
      )

      SourceDoc.reset_cache()
      :ok
    end

    defp set_say_manifest(uuid), do: set_engine_manifest(:say, uuid)
    defp set_emote_manifest(uuid), do: set_engine_manifest(:emote, uuid)

    defp set_engine_manifest(name, uuid) do
      manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})
      Application.put_env(:commonplace, :mud_engine_manifest, Map.put(manifest, name, uuid))
    end

    defp clear_engine_manifest(name) do
      manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})
      Application.put_env(:commonplace, :mud_engine_manifest, Map.delete(manifest, name))
    end

    test "no manifest entry -> the compiled-in floor runs say (silently, no alarm)" do
      permissive!()
      clear_engine_manifest(:say)
      ctx = build_say_ctx()
      Topics.subscribe_room(ctx.current_room_uuid)
      ref = attach_fallback_alarm()

      assert :ok = EngineModule.run_verb(:say, say_cmd("hello"), ctx, @store)
      assert_receive {"red:" <> _, %{kind: :say, who: "alice", text: "hello"}}, 500
      refute_receive {:engine_fallback, ^ref, _}, 100
    end

    test "doc->run: a trusted say doc broadcasts end-to-end via SourceDoc.compile + Gate B" do
      permissive!()
      ctx = build_say_ctx()
      Topics.subscribe_room(ctx.current_room_uuid)
      uuid = mint_say(say_source(), [])
      set_say_manifest(uuid)

      assert {:ok, _module} = SourceDoc.compile(uuid, @store, gate: :execute)

      assert :ok = EngineModule.run_verb(:say, say_cmd("hi there"), ctx, @store)
      assert_receive {"red:" <> _, %{kind: :say, who: "alice", text: "hi there"}}, 500
    end

    test "doc->run: a trusted emote doc broadcasts end-to-end via SourceDoc.compile + Gate B" do
      permissive!()
      ctx = build_say_ctx()
      Topics.subscribe_room(ctx.current_room_uuid)
      uuid = mint_say(emote_source(), [], "_engine_emote.ex")
      set_emote_manifest(uuid)

      assert {:ok, _module} = SourceDoc.compile(uuid, @store, gate: :execute)

      assert :ok = EngineModule.run_verb(:emote, emote_cmd("waves"), ctx, @store)
      assert_receive {"red:" <> _, %{kind: :emote, who: "alice", text: "waves"}}, 500
    end

    test "hot-reload: editing the say doc changes the broadcast kind with no restart" do
      permissive!()
      ctx = build_say_ctx()
      Topics.subscribe_room(ctx.current_room_uuid)
      uuid = mint_say(say_source(), [])
      set_say_manifest(uuid)

      assert :ok = EngineModule.run_verb(:say, say_cmd("hello"), ctx, @store)
      assert_receive {"red:" <> _, %{kind: :say}}, 500

      :ok = edit_say(uuid, say_source() |> String.replace(":say", ":shout"), [])

      assert :ok = EngineModule.run_verb(:say, say_cmd("hello"), ctx, @store)
      assert_receive {"red:" <> _, %{kind: :shout}}, 500
    end

    test "non-brick: a broken EDIT to the say doc falls back to last-good; the world keeps broadcasting + alarms" do
      permissive!()
      ctx = build_say_ctx()
      Topics.subscribe_room(ctx.current_room_uuid)
      ref = attach_fallback_alarm()
      uuid = mint_say(say_source(), [])
      set_say_manifest(uuid)

      assert :ok = EngineModule.run_verb(:say, say_cmd("hello"), ctx, @store)
      assert_receive {"red:" <> _, %{kind: :say, text: "hello"}}, 500

      :ok = edit_say(uuid, broken_source(), [])

      assert :ok = EngineModule.run_verb(:say, say_cmd("still here"), ctx, @store)
      assert_receive {"red:" <> _, %{kind: :say, text: "still here"}}, 500
      assert_receive {:engine_fallback, ^ref, %{name: :say}}, 500
    end

    test "non-brick: a broken-FROM-THE-START say doc falls back to the compiled-in floor" do
      permissive!()
      ctx = build_say_ctx()
      Topics.subscribe_room(ctx.current_room_uuid)
      ref = attach_fallback_alarm()
      uuid = mint_say(broken_source(), [])
      set_say_manifest(uuid)

      assert :ok = EngineModule.run_verb(:say, say_cmd("hello"), ctx, @store)
      assert_receive {"red:" <> _, %{kind: :say, who: "alice", text: "hello"}}, 500
      assert_receive {:engine_fallback, ^ref, _}, 500
    end

    test "non-brick: a say doc that COMPILES but crashes at runtime is contained -> floor" do
      permissive!()
      ctx = build_say_ctx()
      Topics.subscribe_room(ctx.current_room_uuid)
      ref = attach_fallback_alarm()
      uuid = mint_say(crashing_say_source(), [])
      set_say_manifest(uuid)

      assert :ok = EngineModule.run_verb(:say, say_cmd("hello"), ctx, @store)
      assert_receive {"red:" <> _, %{kind: :say, who: "alice", text: "hello"}}, 500
      assert_receive {:engine_fallback, ^ref, _}, 500
    end

    test "RCE guard: a player-signed edit to the say doc is REFUSED (Gate B) -> trusted last-good survives",
         %{trusted: trusted, trusted_id: trusted_id, trusted_pub: trusted_pub, player: player} do
      strict!(%{trusted_id => Signing.encode_key(trusted_pub)})
      ctx = build_say_ctx()
      Topics.subscribe_room(ctx.current_room_uuid)

      uuid = mint_say(say_source(), signing_context: trusted)
      set_say_manifest(uuid)
      assert :ok = EngineModule.run_verb(:say, say_cmd("hello"), ctx, @store)
      assert_receive {"red:" <> _, %{kind: :say, who: "alice", text: "hello"}}, 500

      ref = attach_fallback_alarm()

      :ok =
        edit_say(uuid, say_source() |> String.replace(":say", ":pwned"), signing_context: player)

      assert {:error, {:execution_denied, _}} = SourceDoc.compile(uuid, @store, gate: :execute)

      # revocation-safety invariant (CX-aya0): authority failure -> FLOOR served,
      # never the (now-untrusted) cached last-good.
      assert :ok = EngineModule.run_verb(:say, say_cmd("hello again"), ctx, @store)
      assert_receive {"red:" <> _, %{kind: :say, who: "alice", text: "hello again"}}, 500
      refute_receive {"red:" <> _, %{kind: :pwned}}, 100
      assert_receive {:engine_fallback, ^ref, %{name: :say}}, 500
    end

    test "manifest trust root: a player-authored say doc NOT in the manifest is never resolved",
         %{player: player} do
      permissive!()
      clear_engine_manifest(:say)
      ctx = build_say_ctx()
      Topics.subscribe_room(ctx.current_room_uuid)

      _player_uuid =
        mint_say(say_source() |> String.replace(":say", ":hijacked"), signing_context: player)

      assert :ok = EngineModule.run_verb(:say, say_cmd("hello"), ctx, @store)
      assert_receive {"red:" <> _, %{kind: :say, who: "alice", text: "hello"}}, 500
    end

    test "Bootstrap.ensure_engine_say_verb / ensure_engine_emote_verb seed node-signed docs in parity with the floor" do
      permissive!()
      ctx = build_say_ctx()
      Topics.subscribe_room(ctx.current_room_uuid)

      assert :ok = Commonplace.MUD.Bootstrap.ensure_engine_say_verb(@store)
      assert :ok = Commonplace.MUD.Bootstrap.ensure_engine_emote_verb(@store)

      assert EngineModule.run_verb(:say, say_cmd("hello"), ctx, @store) ==
               SayFloor.run(say_cmd("hello"), ctx)

      assert_receive {"red:" <> _, %{kind: :say, who: "alice", text: "hello"}}, 500

      assert EngineModule.run_verb(:emote, emote_cmd("waves"), ctx, @store) ==
               EmoteFloor.run(emote_cmd("waves"), ctx)

      assert_receive {"red:" <> _, %{kind: :emote, who: "alice", text: "waves"}}, 500
    end
  end

  # ---- CX-wkau (MUD-as-documents Inc-1, tranche 1): the doc-hosted
  # `where`/`examine` gameplay-verb baselines ----
  #
  # `where` is the TRIVIAL member of the six-verb tranche (no target
  # resolution, just `World.get_room/2` + `ctx.current_room_uuid`) —
  # covers doc->run parity/hot-reload, non-brick tiers, the RCE
  # trust-split, and the Bootstrap seed integration, same shape as
  # `look`/`inventory` above.

  describe "where verb (Inc-1 tranche 1)" do
    alias Commonplace.MUD.Schemas
    alias Commonplace.MUD.Schemas.Room
    alias Commonplace.MUD.Verbs.WhereFloor
    alias Commonplace.Tree.Schema

    defp build_where_ctx(room_name \\ "The Vault") do
      root_uuid = UUID.uuid4()
      root_update = Yelixer.Encoding.encode_update(Schema.new_schema())
      CommitStore.create_commit(CommitStore, root_uuid, root_update, nil)

      {:ok, room_uuid} =
        Schemas.create_dir_with_meta(
          Schemas.room_filename(),
          Schemas.encode_room(%Room{name: room_name, description: "A quiet stone vault."}),
          @store
        )

      %{current_room_uuid: room_uuid, store: @store, signing_context: nil}
    end

    defp where_cmd, do: %Parser.Command{verb: "where", argv: [], target: nil}

    defp where_source(name_override \\ nil) do
      name_line =
        if name_override do
          ~s(name = "#{name_override}")
        else
          """
          name = case World.get_room(ctx.current_room_uuid, ctx.store) do
                {:ok, %Room{name: n}} when is_binary(n) and n != "" -> n
                _ -> "here"
              end
          """
        end

      ~s'''
      defmodule Commonplace.MUD.EngineWhere do
        alias Commonplace.MUD.Schemas.Room
        alias Commonplace.MUD.World

        def run(_cmd, ctx) do
          #{name_line}

          {:reply, "You are in \#{name}.\\nuuid: \#{ctx.current_room_uuid}\\n(use this with @link <dir> <uuid> / @teleport <uuid>, or share it so others can link here)"}
        end
      end
      '''
    end

    defp crashing_where_source do
      ~s'''
      defmodule Commonplace.MUD.EngineWhere do
        def run(_cmd, _ctx), do: raise("boom from a doc-hosted where verb")
      end
      '''
    end

    defp where_content_update(source) do
      Yelixer.Doc.new()
      |> ContentType.create(:text, "_engine_where.ex")
      |> ContentType.insert_text(0, source)
      |> Yelixer.Encoding.encode_update()
    end

    defp mint_where(source, opts) do
      uuid = UUID.uuid4()

      CommitStore.create_chained_commit(
        CommitStore,
        uuid,
        where_content_update(source),
        %{kind: :regular},
        opts
      )

      uuid
    end

    defp edit_where(uuid, source, opts) do
      CommitStore.create_chained_commit(
        CommitStore,
        uuid,
        where_content_update(source),
        %{kind: :regular},
        opts
      )

      SourceDoc.reset_cache()
      :ok
    end

    defp set_where_manifest(uuid), do: set_engine_manifest(:where, uuid)
    defp clear_where_manifest, do: clear_engine_manifest(:where)

    test "no manifest entry -> the compiled-in floor runs (silently, no alarm)" do
      permissive!()
      clear_where_manifest()
      ctx = build_where_ctx()
      ref = attach_fallback_alarm()

      assert {:reply, text} = EngineModule.run_verb(:where, where_cmd(), ctx, @store)
      assert {:reply, text} == WhereFloor.run(where_cmd(), ctx)
      refute_receive {:engine_fallback, ^ref, _}, 100
    end

    test "doc->run: a node-signed edit changes where's rendered output (the self-hosting win)" do
      permissive!()
      ctx = build_where_ctx()
      uuid = mint_where(where_source(), [])
      set_where_manifest(uuid)

      assert {:ok, _module} = SourceDoc.compile(uuid, @store, gate: :execute)

      assert {:reply, before_text} = EngineModule.run_verb(:where, where_cmd(), ctx, @store)
      assert before_text =~ "You are in The Vault."

      :ok = edit_where(uuid, where_source("The Renamed Vault"), [])

      assert {:reply, after_text} = EngineModule.run_verb(:where, where_cmd(), ctx, @store)
      assert after_text =~ "You are in The Renamed Vault."
    end

    test "RCE guard: a player-signed edit to the where doc is REFUSED (Gate B) -> floor",
         %{trusted: trusted, trusted_id: trusted_id, trusted_pub: trusted_pub, player: player} do
      strict!(%{trusted_id => Signing.encode_key(trusted_pub)})
      ctx = build_where_ctx()

      uuid = mint_where(where_source(), signing_context: trusted)
      set_where_manifest(uuid)
      assert {:reply, trusted_text} = EngineModule.run_verb(:where, where_cmd(), ctx, @store)
      assert trusted_text =~ "The Vault"

      ref = attach_fallback_alarm()

      :ok = edit_where(uuid, where_source("PWNED"), signing_context: player)

      assert {:error, {:execution_denied, _}} = SourceDoc.compile(uuid, @store, gate: :execute)

      assert {:reply, floor_text} = EngineModule.run_verb(:where, where_cmd(), ctx, @store)
      assert {:reply, floor_text} == WhereFloor.run(where_cmd(), ctx)
      refute floor_text =~ "PWNED"
      assert_receive {:engine_fallback, ^ref, %{name: :where}}, 500
    end

    test "non-brick: a where doc that COMPILES but crashes at runtime is contained -> floor" do
      permissive!()
      ctx = build_where_ctx()
      ref = attach_fallback_alarm()
      uuid = mint_where(crashing_where_source(), [])
      set_where_manifest(uuid)

      assert {:reply, text} = EngineModule.run_verb(:where, where_cmd(), ctx, @store)
      assert {:reply, text} == WhereFloor.run(where_cmd(), ctx)
      assert_receive {:engine_fallback, ^ref, _}, 500
    end

    test "Bootstrap.ensure_engine_where_verb seeds a node-signed where doc that runs in parity with the floor" do
      permissive!()
      ctx = build_where_ctx()

      assert :ok = Commonplace.MUD.Bootstrap.ensure_engine_where_verb(@store)

      assert EngineModule.run_verb(:where, where_cmd(), ctx, @store) ==
               WhereFloor.run(where_cmd(), ctx)
    end
  end

  # `examine` is the RESOLUTION-HEAVY member of the tranche — it goes
  # through `Verbs.resolve_target/2` (the promoted verb-authoring surface
  # wrapping `greedy_match_entry`/`resolve_entry`), so these tests cover a
  # found object AND a missing target, on top of the same doc->run/
  # non-brick/RCE/seed shape as `where` above.

  describe "examine verb (Inc-1 tranche 1)" do
    alias Commonplace.MUD.Schemas
    alias Commonplace.MUD.Schemas.Object
    alias Commonplace.MUD.Verbs.ExamineFloor
    alias Commonplace.Tree.Schema

    defp build_examine_ctx(obj_name \\ "orrery") do
      root_uuid = UUID.uuid4()
      root_update = Yelixer.Encoding.encode_update(Schema.new_schema())
      CommitStore.create_commit(CommitStore, root_uuid, root_update, nil)

      {:ok, room_uuid} = Schemas.create_dir_with_meta(nil, nil, @store)
      {:ok, inventory_uuid} = Schemas.create_dir_with_meta(nil, nil, @store)

      {:ok, obj_uuid} =
        Schemas.create_dir_with_meta(
          Schemas.object_filename(),
          Schemas.encode_object(%Object{
            name: obj_name,
            description: "An intricate brass device."
          }),
          @store
        )

      {:ok, schema} = Schemas.load_dir_schema(room_uuid, @store)
      schema = Schema.add_directory(schema, "#{obj_name}.obj", obj_uuid)
      update = Yelixer.Encoding.encode_update(schema)
      CommitStore.create_chained_commit(CommitStore, room_uuid, update, %{kind: :regular}, [])

      %{
        current_room_uuid: room_uuid,
        inventory_uuid: inventory_uuid,
        store: @store,
        signing_context: nil
      }
    end

    defp examine_cmd(argv),
      do: %Parser.Command{verb: "examine", argv: argv, target: List.first(argv)}

    defp examine_source do
      ~s'''
      defmodule Commonplace.MUD.EngineExamine do
        alias Commonplace.MUD.Schemas.{Object, Player}
        alias Commonplace.MUD.Verbs

        def run(%Commonplace.MUD.Parser.Command{argv: []}, _ctx), do: {:error, "Examine what?"}

        def run(%Commonplace.MUD.Parser.Command{argv: argv}, ctx) do
          phrase_label = Enum.join(argv, " ")

          case Verbs.resolve_target(argv, ctx) do
            {:ok, _node_id, :object, %Object{} = obj} ->
              {:reply, "\#{obj.name}\\n\#{obj.description}"}

            {:ok, _node_id, :player, %Player{} = pl} ->
              title = if pl.title == "", do: pl.name, else: pl.title
              {:reply, "\#{title}\\n\#{pl.description}"}

            _ ->
              {:error, "You don't see \\"\#{phrase_label}\\" here."}
          end
        end
      end
      '''
    end

    defp crashing_examine_source do
      ~s'''
      defmodule Commonplace.MUD.EngineExamine do
        def run(_cmd, _ctx), do: raise("boom from a doc-hosted examine verb")
      end
      '''
    end

    defp examine_content_update(source) do
      Yelixer.Doc.new()
      |> ContentType.create(:text, "_engine_examine.ex")
      |> ContentType.insert_text(0, source)
      |> Yelixer.Encoding.encode_update()
    end

    defp mint_examine(source, opts) do
      uuid = UUID.uuid4()

      CommitStore.create_chained_commit(
        CommitStore,
        uuid,
        examine_content_update(source),
        %{kind: :regular},
        opts
      )

      uuid
    end

    defp edit_examine(uuid, source, opts) do
      CommitStore.create_chained_commit(
        CommitStore,
        uuid,
        examine_content_update(source),
        %{kind: :regular},
        opts
      )

      SourceDoc.reset_cache()
      :ok
    end

    defp set_examine_manifest(uuid), do: set_engine_manifest(:examine, uuid)
    defp clear_examine_manifest, do: clear_engine_manifest(:examine)

    test "no manifest entry -> the compiled-in floor runs (silently, no alarm)" do
      permissive!()
      clear_examine_manifest()
      ctx = build_examine_ctx()
      ref = attach_fallback_alarm()

      assert {:reply, text} =
               EngineModule.run_verb(:examine, examine_cmd(["orrery"]), ctx, @store)

      assert {:reply, text} == ExamineFloor.run(examine_cmd(["orrery"]), ctx)
      refute_receive {:engine_fallback, ^ref, _}, 100
    end

    test "doc->run: a node-signed doc examines a found target AND refuses a missing one (the self-hosting win)" do
      permissive!()
      ctx = build_examine_ctx()
      uuid = mint_examine(examine_source(), [])
      set_examine_manifest(uuid)

      assert {:ok, _module} = SourceDoc.compile(uuid, @store, gate: :execute)

      assert {:reply, text} =
               EngineModule.run_verb(:examine, examine_cmd(["orrery"]), ctx, @store)

      assert text == "orrery\nAn intricate brass device."

      assert {:error, err} =
               EngineModule.run_verb(:examine, examine_cmd(["nonexistent"]), ctx, @store)

      assert err =~ "You don't see"
    end

    test "RCE guard: a player-signed edit to the examine doc is REFUSED (Gate B) -> floor",
         %{trusted: trusted, trusted_id: trusted_id, trusted_pub: trusted_pub, player: player} do
      strict!(%{trusted_id => Signing.encode_key(trusted_pub)})
      ctx = build_examine_ctx()

      uuid = mint_examine(examine_source(), signing_context: trusted)
      set_examine_manifest(uuid)

      assert {:reply, trusted_text} =
               EngineModule.run_verb(:examine, examine_cmd(["orrery"]), ctx, @store)

      assert trusted_text == "orrery\nAn intricate brass device."

      ref = attach_fallback_alarm()

      tampered = String.replace(examine_source(), "obj.description", ~s("PWNED"))
      :ok = edit_examine(uuid, tampered, signing_context: player)

      assert {:error, {:execution_denied, _}} = SourceDoc.compile(uuid, @store, gate: :execute)

      assert {:reply, floor_text} =
               EngineModule.run_verb(:examine, examine_cmd(["orrery"]), ctx, @store)

      assert {:reply, floor_text} == ExamineFloor.run(examine_cmd(["orrery"]), ctx)
      refute floor_text =~ "PWNED"
      assert_receive {:engine_fallback, ^ref, %{name: :examine}}, 500
    end

    test "non-brick: an examine doc that COMPILES but crashes at runtime is contained -> floor" do
      permissive!()
      ctx = build_examine_ctx()
      ref = attach_fallback_alarm()
      uuid = mint_examine(crashing_examine_source(), [])
      set_examine_manifest(uuid)

      assert {:reply, text} =
               EngineModule.run_verb(:examine, examine_cmd(["orrery"]), ctx, @store)

      assert {:reply, text} == ExamineFloor.run(examine_cmd(["orrery"]), ctx)
      assert_receive {:engine_fallback, ^ref, _}, 500
    end

    test "Bootstrap.ensure_engine_examine_verb seeds a node-signed examine doc that runs in parity with the floor" do
      permissive!()
      ctx = build_examine_ctx()

      assert :ok = Commonplace.MUD.Bootstrap.ensure_engine_examine_verb(@store)

      for cmd <- [examine_cmd(["orrery"]), examine_cmd(["nonexistent"]), examine_cmd([])] do
        assert EngineModule.run_verb(:examine, cmd, ctx, @store) == ExamineFloor.run(cmd, ctx),
               "seeded doc-hosted examine of #{inspect(cmd)} must match the floor"
      end
    end
  end

  # `who`/`recipes`/`use` gameplay-verb baselines (CX-wkau tranche 2) ----
  #
  # `who` gets the FULL engine matrix — doc->run parity/hot-reload, non-brick
  # tiers, the RCE trust-split, and the Bootstrap seed integration, same
  # shape as `where`/`examine` above (it's the most interesting of the
  # three: a tree walk + a `Registry` live-presence filter, versus
  # `recipes`'s pure-formatting wrap and `use`'s constant reply). `recipes`
  # and `use` are covered for seed<->floor parity in
  # `engine_verbs_parity_test.exs` instead.

  describe "who verb (Inc-1 tranche 2)" do
    alias Commonplace.MUD.Verbs.WhoFloor
    alias Commonplace.Tree.Schema

    defp build_who_ctx do
      root_uuid = UUID.uuid4()
      root_update = Yelixer.Encoding.encode_update(Schema.new_schema())
      CommitStore.create_commit(CommitStore, root_uuid, root_update, nil)

      %{root_uuid: root_uuid, store: @store, signing_context: nil}
    end

    defp who_cmd, do: %Parser.Command{verb: "who", argv: [], target: nil}

    defp who_source(no_players_override \\ nil) do
      no_players_line =
        if no_players_override do
          ~s("#{no_players_override}")
        else
          "\"Nobody is logged in.\""
        end

      ~s'''
      defmodule Commonplace.MUD.EngineWho do
        alias Commonplace.MUD.Verbs

        def run(_cmd, ctx) do
          names =
            Verbs.walk_collect_players(ctx.root_uuid, ctx.store)
            |> Enum.filter(&live_presence?/1)
            |> Enum.sort()
            |> Enum.uniq()

          text =
            case names do
              [] -> #{no_players_line}
              _ -> "Players online:\\n  - " <> Enum.join(names, "\\n  - ")
            end

          {:reply, text}
        end

        defp live_presence?(name) do
          Registry.lookup(Commonplace.MUD.PresenceRegistry, "\#{name}.usr") != []
        end
      end
      '''
    end

    defp crashing_who_source do
      ~s'''
      defmodule Commonplace.MUD.EngineWho do
        def run(_cmd, _ctx), do: raise("boom from a doc-hosted who verb")
      end
      '''
    end

    defp who_content_update(source) do
      Yelixer.Doc.new()
      |> ContentType.create(:text, "_engine_who.ex")
      |> ContentType.insert_text(0, source)
      |> Yelixer.Encoding.encode_update()
    end

    defp mint_who(source, opts) do
      uuid = UUID.uuid4()

      CommitStore.create_chained_commit(
        CommitStore,
        uuid,
        who_content_update(source),
        %{kind: :regular},
        opts
      )

      uuid
    end

    defp edit_who(uuid, source, opts) do
      CommitStore.create_chained_commit(
        CommitStore,
        uuid,
        who_content_update(source),
        %{kind: :regular},
        opts
      )

      SourceDoc.reset_cache()
      :ok
    end

    defp set_who_manifest(uuid), do: set_engine_manifest(:who, uuid)
    defp clear_who_manifest, do: clear_engine_manifest(:who)

    test "no manifest entry -> the compiled-in floor runs (silently, no alarm)" do
      permissive!()
      clear_who_manifest()
      ctx = build_who_ctx()
      ref = attach_fallback_alarm()

      assert {:reply, text} = EngineModule.run_verb(:who, who_cmd(), ctx, @store)
      assert {:reply, text} == WhoFloor.run(who_cmd(), ctx)
      refute_receive {:engine_fallback, ^ref, _}, 100
    end

    test "doc->run: a node-signed edit changes who's rendered output (the self-hosting win)" do
      permissive!()
      ctx = build_who_ctx()
      uuid = mint_who(who_source(), [])
      set_who_manifest(uuid)

      assert {:ok, _module} = SourceDoc.compile(uuid, @store, gate: :execute)

      assert {:reply, before_text} = EngineModule.run_verb(:who, who_cmd(), ctx, @store)
      assert before_text == "Nobody is logged in."

      :ok = edit_who(uuid, who_source("The halls stand empty."), [])

      assert {:reply, after_text} = EngineModule.run_verb(:who, who_cmd(), ctx, @store)
      assert after_text == "The halls stand empty."
    end

    test "RCE guard: a player-signed edit to the who doc is REFUSED (Gate B) -> floor",
         %{trusted: trusted, trusted_id: trusted_id, trusted_pub: trusted_pub, player: player} do
      strict!(%{trusted_id => Signing.encode_key(trusted_pub)})
      ctx = build_who_ctx()

      uuid = mint_who(who_source(), signing_context: trusted)
      set_who_manifest(uuid)
      assert {:reply, trusted_text} = EngineModule.run_verb(:who, who_cmd(), ctx, @store)
      assert trusted_text == "Nobody is logged in."

      ref = attach_fallback_alarm()

      :ok = edit_who(uuid, who_source("PWNED"), signing_context: player)

      assert {:error, {:execution_denied, _}} = SourceDoc.compile(uuid, @store, gate: :execute)

      assert {:reply, floor_text} = EngineModule.run_verb(:who, who_cmd(), ctx, @store)
      assert {:reply, floor_text} == WhoFloor.run(who_cmd(), ctx)
      refute floor_text =~ "PWNED"
      assert_receive {:engine_fallback, ^ref, %{name: :who}}, 500
    end

    test "non-brick: a who doc that COMPILES but crashes at runtime is contained -> floor" do
      permissive!()
      ctx = build_who_ctx()
      ref = attach_fallback_alarm()
      uuid = mint_who(crashing_who_source(), [])
      set_who_manifest(uuid)

      assert {:reply, text} = EngineModule.run_verb(:who, who_cmd(), ctx, @store)
      assert {:reply, text} == WhoFloor.run(who_cmd(), ctx)
      assert_receive {:engine_fallback, ^ref, _}, 500
    end

    test "Bootstrap.ensure_engine_who_verb seeds a node-signed who doc that runs in parity with the floor" do
      permissive!()
      ctx = build_who_ctx()

      assert :ok = Commonplace.MUD.Bootstrap.ensure_engine_who_verb(@store)

      assert EngineModule.run_verb(:who, who_cmd(), ctx, @store) == WhoFloor.run(who_cmd(), ctx)
    end
  end

  # CX-wkau (Inc-1, tranche 3) — the first TRUST-ADJACENT verb: `go` moves
  # player presence through `World.move_presence/5`, the CX-avzp read-gated
  # chokepoint. That chokepoint stays kernel-side; only the orchestration
  # (direction/exit lookup, depart/arrive broadcasts, error strings) is
  # doc-hosted — same doc->run/non-brick/RCE/seed shape as `where`/`who`
  # above, PLUS a real end-to-end move (requires a `Green.Bursar` — `Move`
  # takes exclusive tokens on the source/dest dir schemas) to prove the
  # chokepoint is honored identically on both paths. The dedicated
  # `CxAvzpPrivateRoomTest` covers the actual eavesdrop/denial pin
  # (duplicated onto this doc path there); this describe covers the
  # floor/node-edit/player-signed-refused/crash-contained matrix plus
  # valid-move / bad-direction parity.
  describe "go verb (Inc-1 tranche 3)" do
    alias Commonplace.Green.Bursar
    alias Commonplace.MUD.Schemas
    alias Commonplace.MUD.Schemas.Room
    alias Commonplace.MUD.Verbs.GoFloor
    alias Commonplace.Tree.Schema

    setup do
      case GenServer.whereis(Bursar) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end

      bursar_root = UUID.uuid4()
      {:ok, bursar_pid} = Bursar.start_link(root_uuid: bursar_root, store: @store, sweep_interval: 60_000)
      on_exit(fn -> if Process.alive?(bursar_pid), do: (try do GenServer.stop(bursar_pid) catch (:exit, _ -> :ok) end) end)
      :ok
    end

    # A minimal but real ctx: a src room with a "north" exit to a dest room,
    # and a presence entry (`presence_filename` -> `player_uuid`) seeded
    # directly into the src room's schema — the shape `Move.move/5` requires
    # (it moves the NAMED schema entry, checking it's still `player_uuid`).
    defp build_go_ctx(name \\ "alice") do
      root_uuid = UUID.uuid4()
      CommitStore.create_commit(CommitStore, root_uuid, Yelixer.Encoding.encode_update(Schema.new_schema()), nil)

      {:ok, dest_uuid} =
        Schemas.create_dir_with_meta(
          Schemas.room_filename(),
          Schemas.encode_room(%Room{name: "Dest", description: "A dest room."}),
          @store
        )

      {:ok, src_uuid} =
        Schemas.create_dir_with_meta(
          Schemas.room_filename(),
          Schemas.encode_room(%Room{name: "Src", description: "A src room.", exits: %{"north" => dest_uuid}}),
          @store
        )

      player_uuid = UUID.uuid4()
      presence_filename = "#{name}.usr"

      {:ok, src_schema} = Schemas.load_dir_schema(src_uuid, @store)
      src_schema = Schema.add_file(src_schema, presence_filename, player_uuid)

      CommitStore.create_chained_commit(
        CommitStore,
        src_uuid,
        Yelixer.Encoding.encode_update(src_schema),
        %{kind: :regular},
        []
      )

      %{
        player_uuid: player_uuid,
        player_name: name,
        presence_filename: presence_filename,
        current_room_uuid: src_uuid,
        dest_uuid: dest_uuid,
        root_uuid: root_uuid,
        store: @store,
        signing_context: nil
      }
    end

    defp go_cmd(argv \\ []), do: %Parser.Command{verb: "go", argv: argv, target: List.first(argv)}

    defp go_source(no_direction_reply \\ nil) do
      no_direction_line =
        if no_direction_reply do
          ~s("#{no_direction_reply}")
        else
          "\"Go where?\""
        end

      ~s'''
      defmodule Commonplace.MUD.EngineGo do
        alias Commonplace.MUD.{Parser, Verbs, World}
        alias Commonplace.MUD.Schemas.Room

        @directions ~w(north south east west up down in out)

        def run(cmd, ctx) do
          direction = if cmd.verb in @directions, do: cmd.verb, else: List.first(cmd.argv)
          do_go(direction, ctx)
        end

        defp do_go(nil, _ctx), do: {:error, #{no_direction_line}}

        defp do_go(direction, ctx) do
          with {:ok, %Room{} = room} <- World.get_room(ctx.current_room_uuid, ctx.store),
               {:ok, dest_uuid} <- Map.fetch(room.exits, direction),
               :ok <-
                 World.move_presence(
                   ctx.player_uuid,
                   ctx.presence_filename,
                   ctx.current_room_uuid,
                   dest_uuid,
                   Verbs.invoker_move_opts(ctx)
                 ) do
            World.broadcast_room(ctx.current_room_uuid, %{kind: :depart, who: ctx.player_name, to: direction})
            from_dir = Parser.opposite_direction(direction) || "elsewhere"
            World.broadcast_room(dest_uuid, %{kind: :arrive, who: ctx.player_name, from: from_dir})
            {:moved, dest_uuid}
          else
            :error -> {:error, "You can't go \#{direction}."}
            {:error, :gone} -> {:error, "The way \#{direction} closed behind you."}
            {:error, :collision} -> {:error, "Something blocks the way \#{direction}."}
            {:error, :read_denied} -> {:error, "That place is private."}
            {:error, {:trust_rejected, _}} -> {:error, "You don't have permission to go \#{direction}."}
            _ -> {:error, "You can't go \#{direction}."}
          end
        end
      end
      '''
    end

    defp crashing_go_source do
      ~s'''
      defmodule Commonplace.MUD.EngineGo do
        def run(_cmd, _ctx), do: raise("boom from a doc-hosted go verb")
      end
      '''
    end

    defp go_content_update(source) do
      Yelixer.Doc.new()
      |> ContentType.create(:text, "_engine_go.ex")
      |> ContentType.insert_text(0, source)
      |> Yelixer.Encoding.encode_update()
    end

    defp mint_go(source, opts) do
      uuid = UUID.uuid4()
      CommitStore.create_chained_commit(CommitStore, uuid, go_content_update(source), %{kind: :regular}, opts)
      uuid
    end

    defp edit_go(uuid, source, opts) do
      CommitStore.create_chained_commit(CommitStore, uuid, go_content_update(source), %{kind: :regular}, opts)
      SourceDoc.reset_cache()
      :ok
    end

    defp set_go_manifest(uuid), do: set_engine_manifest(:go, uuid)
    defp clear_go_manifest, do: clear_engine_manifest(:go)

    test "no manifest entry -> the compiled-in floor runs (silently, no alarm)" do
      permissive!()
      clear_go_manifest()
      ctx = build_go_ctx()
      ref = attach_fallback_alarm()

      assert {:error, text} = EngineModule.run_verb(:go, go_cmd(), ctx, @store)
      assert {:error, text} == GoFloor.run(go_cmd(), ctx)
      assert text == "Go where?"
      refute_receive {:engine_fallback, ^ref, _}, 100
    end

    test "doc->run: a node-signed edit changes go's error text (the self-hosting win)" do
      permissive!()
      ctx = build_go_ctx()
      uuid = mint_go(go_source(), [])
      set_go_manifest(uuid)

      assert {:ok, _module} = SourceDoc.compile(uuid, @store, gate: :execute)

      assert {:error, "Go where?"} = EngineModule.run_verb(:go, go_cmd(), ctx, @store)

      :ok = edit_go(uuid, go_source("Which way, friend?"), [])

      assert {:error, "Which way, friend?"} = EngineModule.run_verb(:go, go_cmd(), ctx, @store)
    end

    test "RCE guard: a player-signed edit to the go doc is REFUSED (Gate B) -> trusted last-good survives",
         %{trusted: trusted, trusted_id: trusted_id, trusted_pub: trusted_pub, player: player} do
      strict!(%{trusted_id => Signing.encode_key(trusted_pub)})
      ctx = build_go_ctx()

      uuid = mint_go(go_source(), signing_context: trusted)
      set_go_manifest(uuid)
      assert {:error, "Go where?"} = EngineModule.run_verb(:go, go_cmd(), ctx, @store)

      ref = attach_fallback_alarm()

      :ok = edit_go(uuid, go_source("PWNED"), signing_context: player)

      assert {:error, {:execution_denied, _}} = SourceDoc.compile(uuid, @store, gate: :execute)

      assert {:error, floor_text} = EngineModule.run_verb(:go, go_cmd(), ctx, @store)
      assert {:error, floor_text} == GoFloor.run(go_cmd(), ctx)
      refute floor_text =~ "PWNED"
      assert_receive {:engine_fallback, ^ref, %{name: :go}}, 500
    end

    test "non-brick: a go doc that COMPILES but crashes at runtime is contained -> floor" do
      permissive!()
      ctx = build_go_ctx()
      ref = attach_fallback_alarm()
      uuid = mint_go(crashing_go_source(), [])
      set_go_manifest(uuid)

      assert {:error, text} = EngineModule.run_verb(:go, go_cmd(), ctx, @store)
      assert {:error, text} == GoFloor.run(go_cmd(), ctx)
      assert_receive {:engine_fallback, ^ref, _}, 500
    end

    test "Bootstrap.ensure_engine_go_verb: a bad direction errors identically to the floor" do
      permissive!()
      ctx = build_go_ctx()

      assert :ok = Commonplace.MUD.Bootstrap.ensure_engine_go_verb(@store)

      assert EngineModule.run_verb(:go, go_cmd(["nonexistent"]), ctx, @store) ==
               GoFloor.run(go_cmd(["nonexistent"]), ctx)

      assert {:error, "You can't go nonexistent."} = EngineModule.run_verb(:go, go_cmd(["nonexistent"]), ctx, @store)
    end

    test "Bootstrap.ensure_engine_go_verb: a valid move succeeds identically to the floor (CX-avzp chokepoint honored)" do
      permissive!()
      assert :ok = Commonplace.MUD.Bootstrap.ensure_engine_go_verb(@store)

      # Separate ctx instances (each its own fresh src/dest pair) — the doc
      # path is exercised against one, the floor against the other, since
      # a real move mutates schema state (can't replay the same ctx twice).
      doc_ctx = build_go_ctx("doc-mover")
      floor_ctx = build_go_ctx("floor-mover")

      assert {:moved, doc_dest} = EngineModule.run_verb(:go, go_cmd(["north"]), doc_ctx, @store)
      assert doc_dest == doc_ctx.dest_uuid

      assert {:moved, floor_dest} = GoFloor.run(go_cmd(["north"]), floor_ctx)
      assert floor_dest == floor_ctx.dest_uuid

      # Presence actually transferred identically on both paths.
      {:ok, doc_dest_schema} = Schemas.load_dir_schema(doc_ctx.dest_uuid, @store)
      assert Enum.any?(Schema.list_entries(doc_dest_schema), &(&1.name == doc_ctx.presence_filename))

      {:ok, floor_dest_schema} = Schemas.load_dir_schema(floor_ctx.dest_uuid, @store)
      assert Enum.any?(Schema.list_entries(floor_dest_schema), &(&1.name == floor_ctx.presence_filename))
    end
  end

  # CX-wkau (Inc-1, tranche 3) — `home` is also TRUST-ADJACENT: it teleports
  # the player to their own `players/<name>/` room via the SAME
  # `World.move_presence/5` chokepoint `go` uses (through the compiled-in
  # `do_home/1` -> `do_teleport/2` path). Same shape as the `go` describe
  # above, minus direction resolution.
  describe "home verb (Inc-1 tranche 3)" do
    alias Commonplace.Green.Bursar
    alias Commonplace.MUD.Schemas
    alias Commonplace.MUD.Schemas.Room
    alias Commonplace.MUD.Verbs.HomeFloor
    alias Commonplace.Tree.Schema

    setup do
      case GenServer.whereis(Bursar) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end

      bursar_root = UUID.uuid4()
      {:ok, bursar_pid} = Bursar.start_link(root_uuid: bursar_root, store: @store, sweep_interval: 60_000)
      on_exit(fn -> if Process.alive?(bursar_pid), do: (try do GenServer.stop(bursar_pid) catch (:exit, _ -> :ok) end) end)
      :ok
    end

    defp home_cmd, do: %Parser.Command{verb: "home", argv: [], target: nil}

    # No `players/<name>` path at all -> the structural-absence branch
    # (`do_home/1`'s `else` clause) — safe to reuse across doc/floor calls
    # since nothing is written.
    defp build_no_home_ctx(name \\ "bob") do
      root_uuid = UUID.uuid4()
      CommitStore.create_commit(CommitStore, root_uuid, Yelixer.Encoding.encode_update(Schema.new_schema()), nil)

      {:ok, room_uuid} =
        Schemas.create_dir_with_meta(
          Schemas.room_filename(),
          Schemas.encode_room(%Room{name: "Start", description: "The starting room."}),
          @store
        )

      %{
        player_uuid: UUID.uuid4(),
        player_name: name,
        presence_filename: "#{name}.usr",
        current_room_uuid: room_uuid,
        root_uuid: root_uuid,
        store: @store,
        signing_context: nil
      }
    end

    # A full `players/<name>/` home room + a separate starting room with the
    # player's presence seeded in it — the shape a real move needs.
    defp build_home_ctx(name) do
      root_uuid = UUID.uuid4()
      CommitStore.create_commit(CommitStore, root_uuid, Yelixer.Encoding.encode_update(Schema.new_schema()), nil)

      {:ok, home_uuid} =
        Schemas.create_dir_with_meta(
          Schemas.room_filename(),
          Schemas.encode_room(%Room{name: "#{name}'s Home", description: "Cozy."}),
          @store
        )

      {:ok, start_uuid} =
        Schemas.create_dir_with_meta(
          Schemas.room_filename(),
          Schemas.encode_room(%Room{name: "Start", description: "The starting room."}),
          @store
        )

      players_uuid = UUID.uuid4()
      players_schema = Schema.add_directory(Schema.new_schema(), name, home_uuid)
      CommitStore.create_commit(CommitStore, players_uuid, Yelixer.Encoding.encode_update(players_schema), nil)

      {:ok, root_schema} = Schemas.load_dir_schema(root_uuid, @store)
      root_schema = Schema.add_directory(root_schema, "players", players_uuid)

      CommitStore.create_chained_commit(
        CommitStore,
        root_uuid,
        Yelixer.Encoding.encode_update(root_schema),
        %{kind: :regular},
        []
      )

      player_uuid = UUID.uuid4()
      presence_filename = "#{name}.usr"

      {:ok, start_schema} = Schemas.load_dir_schema(start_uuid, @store)
      start_schema = Schema.add_file(start_schema, presence_filename, player_uuid)

      CommitStore.create_chained_commit(
        CommitStore,
        start_uuid,
        Yelixer.Encoding.encode_update(start_schema),
        %{kind: :regular},
        []
      )

      %{
        player_uuid: player_uuid,
        player_name: name,
        presence_filename: presence_filename,
        current_room_uuid: start_uuid,
        home_uuid: home_uuid,
        root_uuid: root_uuid,
        store: @store,
        signing_context: nil
      }
    end

    defp home_source(no_home_reply \\ nil) do
      no_home_line =
        if no_home_reply do
          ~s("#{no_home_reply}")
        else
          "\"You don't seem to have a home to return to yet.\""
        end

      ~s'''
      defmodule Commonplace.MUD.EngineHome do
        alias Commonplace.MUD.{Verbs, World}
        alias Commonplace.MUD.Schemas.Room

        def run(_cmd, ctx) do
          with {:ok, home_uuid} <- World.resolve_path("players/\#{ctx.player_name}", ctx.root_uuid, ctx.store),
               {:ok, %Room{}} <- World.get_room(home_uuid, ctx.store) do
            move_home(home_uuid, ctx)
          else
            _ -> {:error, #{no_home_line}}
          end
        end

        defp move_home(home_uuid, ctx) do
          case World.move_presence(
                 ctx.player_uuid,
                 ctx.presence_filename,
                 ctx.current_room_uuid,
                 home_uuid,
                 Verbs.invoker_move_opts(ctx)
               ) do
            :ok ->
              World.broadcast_room(ctx.current_room_uuid, %{kind: :depart, who: ctx.player_name, to: "elsewhere"})
              World.broadcast_room(home_uuid, %{kind: :arrive, who: ctx.player_name, from: "elsewhere"})
              {:moved, home_uuid}

            {:error, :gone} -> {:error, "You couldn't teleport away — try again."}
            {:error, :collision} -> {:error, "Something blocks your arrival there."}
            {:error, :read_denied} -> {:error, "That place is private."}
            {:error, {:trust_rejected, _}} -> {:error, "You don't have permission to teleport there."}
            _ -> {:error, "Teleport failed."}
          end
        end
      end
      '''
    end

    defp crashing_home_source do
      ~s'''
      defmodule Commonplace.MUD.EngineHome do
        def run(_cmd, _ctx), do: raise("boom from a doc-hosted home verb")
      end
      '''
    end

    defp home_content_update(source) do
      Yelixer.Doc.new()
      |> ContentType.create(:text, "_engine_home.ex")
      |> ContentType.insert_text(0, source)
      |> Yelixer.Encoding.encode_update()
    end

    defp mint_home(source, opts) do
      uuid = UUID.uuid4()
      CommitStore.create_chained_commit(CommitStore, uuid, home_content_update(source), %{kind: :regular}, opts)
      uuid
    end

    defp edit_home(uuid, source, opts) do
      CommitStore.create_chained_commit(CommitStore, uuid, home_content_update(source), %{kind: :regular}, opts)
      SourceDoc.reset_cache()
      :ok
    end

    defp set_home_manifest(uuid), do: set_engine_manifest(:home, uuid)
    defp clear_home_manifest, do: clear_engine_manifest(:home)

    test "no manifest entry -> the compiled-in floor runs (silently, no alarm)" do
      permissive!()
      clear_home_manifest()
      ctx = build_no_home_ctx()
      ref = attach_fallback_alarm()

      assert {:error, text} = EngineModule.run_verb(:home, home_cmd(), ctx, @store)
      assert {:error, text} == HomeFloor.run(home_cmd(), ctx)
      assert text == "You don't seem to have a home to return to yet."
      refute_receive {:engine_fallback, ^ref, _}, 100
    end

    test "doc->run: a node-signed edit changes home's no-home error text (the self-hosting win)" do
      permissive!()
      ctx = build_no_home_ctx()
      uuid = mint_home(home_source(), [])
      set_home_manifest(uuid)

      assert {:ok, _module} = SourceDoc.compile(uuid, @store, gate: :execute)

      assert {:error, "You don't seem to have a home to return to yet."} =
               EngineModule.run_verb(:home, home_cmd(), ctx, @store)

      :ok = edit_home(uuid, home_source("No home yet, adventurer."), [])

      assert {:error, "No home yet, adventurer."} = EngineModule.run_verb(:home, home_cmd(), ctx, @store)
    end

    test "RCE guard: a player-signed edit to the home doc is REFUSED (Gate B) -> trusted last-good survives",
         %{trusted: trusted, trusted_id: trusted_id, trusted_pub: trusted_pub, player: player} do
      strict!(%{trusted_id => Signing.encode_key(trusted_pub)})
      ctx = build_no_home_ctx()

      uuid = mint_home(home_source(), signing_context: trusted)
      set_home_manifest(uuid)

      assert {:error, "You don't seem to have a home to return to yet."} =
               EngineModule.run_verb(:home, home_cmd(), ctx, @store)

      ref = attach_fallback_alarm()

      :ok = edit_home(uuid, home_source("PWNED"), signing_context: player)

      assert {:error, {:execution_denied, _}} = SourceDoc.compile(uuid, @store, gate: :execute)

      assert {:error, floor_text} = EngineModule.run_verb(:home, home_cmd(), ctx, @store)
      assert {:error, floor_text} == HomeFloor.run(home_cmd(), ctx)
      refute floor_text =~ "PWNED"
      assert_receive {:engine_fallback, ^ref, %{name: :home}}, 500
    end

    test "non-brick: a home doc that COMPILES but crashes at runtime is contained -> floor" do
      permissive!()
      ctx = build_no_home_ctx()
      ref = attach_fallback_alarm()
      uuid = mint_home(crashing_home_source(), [])
      set_home_manifest(uuid)

      assert {:error, text} = EngineModule.run_verb(:home, home_cmd(), ctx, @store)
      assert {:error, text} == HomeFloor.run(home_cmd(), ctx)
      assert_receive {:engine_fallback, ^ref, _}, 500
    end

    test "Bootstrap.ensure_engine_home_verb: the no-home-room case errors identically to the floor" do
      permissive!()
      ctx = build_no_home_ctx()

      assert :ok = Commonplace.MUD.Bootstrap.ensure_engine_home_verb(@store)

      assert EngineModule.run_verb(:home, home_cmd(), ctx, @store) == HomeFloor.run(home_cmd(), ctx)

      assert {:error, "You don't seem to have a home to return to yet."} =
               EngineModule.run_verb(:home, home_cmd(), ctx, @store)
    end

    test "Bootstrap.ensure_engine_home_verb: a valid move succeeds identically to the floor (CX-avzp chokepoint honored)" do
      permissive!()
      assert :ok = Commonplace.MUD.Bootstrap.ensure_engine_home_verb(@store)

      doc_ctx = build_home_ctx("doc-mover")
      floor_ctx = build_home_ctx("floor-mover")

      assert {:moved, doc_home} = EngineModule.run_verb(:home, home_cmd(), doc_ctx, @store)
      assert doc_home == doc_ctx.home_uuid

      assert {:moved, floor_home} = HomeFloor.run(home_cmd(), floor_ctx)
      assert floor_home == floor_ctx.home_uuid

      {:ok, doc_home_schema} = Schemas.load_dir_schema(doc_ctx.home_uuid, @store)
      assert Enum.any?(Schema.list_entries(doc_home_schema), &(&1.name == doc_ctx.presence_filename))

      {:ok, floor_home_schema} = Schemas.load_dir_schema(floor_ctx.home_uuid, @store)
      assert Enum.any?(Schema.list_entries(floor_home_schema), &(&1.name == floor_ctx.presence_filename))
    end
  end
end

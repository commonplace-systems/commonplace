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
    trusted = %SigningContext{identity_uuid: trusted_id, public_key: trusted_pub, private_key: trusted_priv}

    {player_pub, player_priv} = Signing.generate_keypair()
    player_id = "b0b22222-0000-0000-0000-#{:rand.uniform(999_999_999_999)}"
    player = %SigningContext{identity_uuid: player_id, public_key: player_pub, private_key: player_priv}

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
      {:ok, _pid} = Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"})
      Commonplace.Tree.DocCache.clear()
      SourceDoc.reset_cache()
      File.rm_rf!(dir)
    end)

    %{trusted: trusted, trusted_id: trusted_id, trusted_pub: trusted_pub, player: player}
  end

  # --- helpers ---

  defp permissive!, do: Application.put_env(:commonplace, :trust, %{accept_unsigned: true, trusted_identities: %{}})

  defp strict!(trusted), do: Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: trusted})

  defp set_manifest(uuid), do: Application.put_env(:commonplace, :mud_engine_manifest, %{parser: uuid})
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
    CommitStore.create_chained_commit(CommitStore, uuid, content_update(source), %{kind: :regular}, opts)
    uuid
  end

  defp edit(uuid, source, opts) do
    CommitStore.create_chained_commit(CommitStore, uuid, content_update(source), %{kind: :regular}, opts)
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
    assert %Parser.Command{verb: "take", target: "orrery"} = EngineModule.parse("grab orrery", @store)
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
    assert %Parser.Command{verb: "take", target: "orrery"} = EngineModule.parse("take orrery", @store)
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

    # And the resolver keeps the TRUSTED last-good — the injected grammar never
    # runs ("pwn" is NOT aliased to "hacked"; it parses as the literal verb).
    assert %Parser.Command{verb: "pwn"} = EngineModule.parse("pwn orrery", @store)
    assert %Parser.Command{verb: "take", target: "orrery"} = EngineModule.parse("take orrery", @store)
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
end

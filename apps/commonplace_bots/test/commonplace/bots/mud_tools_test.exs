defmodule Commonplace.Bots.MudToolsTest do
  @moduledoc """
  Camillo slice C3c — the minimal DEMO tools (`move` / `look` / `scratch`) that
  make a heartbeat turn VISIBLE: the bot walks the MUD and jots to its wiki
  scratchpad, no chat involved.

  Most tests run against a permissive (`:dry_run`) local write gate — the same
  posture the `memory.jsonl` / `agenda.jsonl` append tests use — so the focus is
  the tools' BEHAVIOR (presence physically moves, the snapshot renders, the
  scratchpad grows under `home/scratch/<page>/`, path-escapes are refused) and
  that every write is genuinely BOT-signed. One scratch test additionally PINS
  the write under real `local_write_gate: :enforce` + strict trust (the whole
  point of the C3c re-anchor: the zoned note-meta is covered by the bot's
  `{:subtree, home}` cert, so it LANDS rather than being denied
  `:capability_insufficient`). The three pins are asserted directly:
  position is re-read from the live `.usr` presence (a), the move bottoms out on
  `World.move_presence/5` (b), and the ctx is assembled only from the signing
  context + Citizenship certs + the MUD root (c).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.Identity, as: BotIdentity
  alias Commonplace.Bots.{Agenda, Citizen, MudContext, NoteDoc}
  alias Commonplace.Bots.Worker.Tools
  alias Commonplace.Bots.Worker.Tools.{Look, Move, ReadMemory, Remember, Scratch, UpdateAgenda}
  alias Commonplace.Crypto.Signing
  alias Commonplace.MUD.World
  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    n = :rand.uniform(1_000_000_000)
    dir = Path.join(System.tmp_dir!(), "cp_bots_mudtools_#{n}")
    File.mkdir_p!(dir)
    store = :"mudtools_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"mudtools_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"mudtools_tss_#{n}",
       pending_imports_name: :"mudtools_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    # Presence moves take green tokens (World.move -> Move.move -> Bursar), so a
    # Bursar must run under its default name for the shared motion path to work.
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

    secrets_dir = Path.join(System.tmp_dir!(), "cp_bots_mudtools_secrets_#{n}")
    File.mkdir_p!(secrets_dir)
    secrets = :"mudtools_secrets_#{n}"
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

    # The MUD root — a schema doc, node-signed.
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

  # Provision "camillo" as a citizen (home -> foyer -> study, presence in foyer),
  # then resolve his MUD ctx the SAME way the Worker does per turn.
  defp resolve_camillo(ctx) do
    {:ok, prov} = Citizen.provision("camillo", ctx.mud_root, ctx.store, secret_store: ctx.secrets)

    {:ok, sc} =
      BotIdentity.resolve_signing_context("camillo", ctx.mud_root, ctx.store,
        secret_store: ctx.secrets
      )

    {:ok, mud_ctx} = MudContext.resolve(%{name: "camillo"}, sc, ctx.mud_root, ctx.store)
    {prov, sc, mud_ctx}
  end

  test "MudContext ctx is assembled from sc + certs + root (pin c), not caller args", ctx do
    {prov, sc, mud_ctx} = resolve_camillo(ctx)

    # signer_id is DERIVED from the signing context, not supplied.
    assert mud_ctx.signer_id == Signing.signer_id(sc.identity_uuid, sc.public_key)
    # cert_cids come straight from Citizenship.ensure (non-empty for a citizen).
    assert is_list(mud_ctx.cert_cids) and mud_ctx.cert_cids != []
    assert mud_ctx.root_uuid == ctx.mud_root
    assert mud_ctx.signing_context == sc
    assert mud_ctx.presence_filename == "camillo.usr"
    # Position resolved from the live presence — provision stood him in the foyer.
    assert mud_ctx.current_room_uuid == prov.foyer_uuid
  end

  test "move: walks the presence to the adjacent room via World.move_presence (pin b)", ctx do
    {prov, _sc, mud_ctx} = resolve_camillo(ctx)

    # Presence starts in the foyer.
    assert {:ok, room} = World.find_presence_room(ctx.mud_root, "camillo.usr", ctx.store)
    assert room == prov.foyer_uuid

    # Walk north (foyer --north--> study, a real C2 seed exit).
    assert {:ok, text} = Move.call(%{mud_ctx: mud_ctx}, %{"direction" => "north"})
    assert text =~ "You walk north"

    # The .usr presence PHYSICALLY moved: find_presence_room now returns study.
    assert {:ok, moved_room} = World.find_presence_room(ctx.mud_root, "camillo.usr", ctx.store)
    assert moved_room == prov.study_uuid
    refute moved_room == prov.foyer_uuid
  end

  test "move: a bad direction is a sanitized refusal (no internals)", ctx do
    {_prov, _sc, mud_ctx} = resolve_camillo(ctx)

    assert {:error, "You can't go that way."} =
             Move.call(%{mud_ctx: mud_ctx}, %{"direction" => "up"})
  end

  test "move: no mud_ctx (unprovisioned) refuses gracefully", _ctx do
    assert {:error, "You are not in the world."} =
             Move.call(%{mud_ctx: nil}, %{"direction" => "north"})
  end

  test "position is RE-READ every resolve, never cached (pin a)", ctx do
    {prov, sc, mud_ctx1} = resolve_camillo(ctx)
    assert mud_ctx1.current_room_uuid == prov.foyer_uuid

    # An EXTERNAL move of the presence (not through this ctx) — as if a summon or
    # another actor relocated the bot's .usr.
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

    # Resolving AGAIN reflects the new position — proof it's read fresh, not the
    # stale foyer stashed in the first ctx.
    {:ok, mud_ctx2} = MudContext.resolve(%{name: "camillo"}, sc, ctx.mud_root, ctx.store)
    assert mud_ctx2.current_room_uuid == prov.study_uuid
    assert mud_ctx1.current_room_uuid == prov.foyer_uuid
  end

  test "look: returns the current room's snapshot text", ctx do
    {_prov, _sc, mud_ctx} = resolve_camillo(ctx)

    assert {:ok, text} = Look.call(%{mud_ctx: mud_ctx}, %{})
    # The foyer has a north exit (to study) and a south exit (back home).
    assert text =~ "Foyer"
    assert text =~ "Exits"
    assert text =~ "north"
  end

  test "look: no mud_ctx refuses gracefully", _ctx do
    assert {:error, "You are not in the world."} = Look.call(%{mud_ctx: nil}, %{})
  end

  test "scratch: jots to home/scratch/<page> as a zoned note-meta, bot-signed", ctx do
    {prov, sc, mud_ctx} = resolve_camillo(ctx)

    assert {:ok, msg} = Scratch.call(%{mud_ctx: mud_ctx}, %{"note" => "hello from the heartbeat"})
    assert msg =~ "scratch"

    # The note lands under home/scratch/notes (default page) as the "text" field
    # of the page's __note.json note-meta.
    {:ok, page_uuid} = page_dir(mud_ctx, "notes")
    {:ok, note_map} = World.get_meta_map(page_uuid, "__note.json", ctx.store)
    assert note_map["text"] =~ "hello from the heartbeat"

    # The page is a ZONED child of the home — zone inherits == home.
    assert note_map["zone"] == prov.home_room_uuid

    # The append is BOT-signed (not node-signed) — the LATEST commit on the
    # __note.json meta doc.
    bot_signer = Signing.signer_id(sc.identity_uuid, sc.public_key)
    {:ok, meta_uuid} = World.meta_doc_uuid(page_uuid, "__note.json", ctx.store)
    {:ok, commit} = CommitStore.latest_commit(ctx.store, meta_uuid)
    assert commit.signer_id == bot_signer

    # A named page is honored.
    assert {:ok, _} = Scratch.call(%{mud_ctx: mud_ctx}, %{"note" => "todo", "page" => "agenda"})
    {:ok, agenda_uuid} = page_dir(mud_ctx, "agenda")
    {:ok, agenda_map} = World.get_meta_map(agenda_uuid, "__note.json", ctx.store)
    assert agenda_map["text"] =~ "todo"
  end

  test "scratch: the zone stamp SURVIVES an append (merge_meta, no round-trip)", ctx do
    {prov, _sc, mud_ctx} = resolve_camillo(ctx)

    assert {:ok, _} = Scratch.call(%{mud_ctx: mud_ctx}, %{"note" => "first note"})
    assert {:ok, _} = Scratch.call(%{mud_ctx: mud_ctx}, %{"note" => "second note"})

    {:ok, page_uuid} = page_dir(mud_ctx, "notes")
    {:ok, note_map} = World.get_meta_map(page_uuid, "__note.json", ctx.store)

    # The node-signed zone stamp is STILL present after two appends (a %Struct{}
    # round-trip would have dropped it — CX-cl65). It equals the home zone.
    assert note_map["zone"] == prov.home_room_uuid
    # Both notes are in the "text" field (append-only).
    assert note_map["text"] =~ "first note"
    assert note_map["text"] =~ "second note"
  end

  test "scratch: a path-escape page is REFUSED and writes nothing outside the namespace", ctx do
    {_prov, _sc, mud_ctx} = resolve_camillo(ctx)

    # A first valid jot so the home/scratch dir exists.
    assert {:ok, _} = Scratch.call(%{mud_ctx: mud_ctx}, %{"note" => "seed"})

    # The escape attempt is refused BEFORE any write.
    assert {:error, "Bad page name."} =
             Scratch.call(%{mud_ctx: mud_ctx}, %{"note" => "pwn", "page" => "../../etc"})

    assert {:error, "Bad page name."} =
             Scratch.call(%{mud_ctx: mud_ctx}, %{"note" => "pwn", "page" => "a/b"})

    # Nothing landed outside home/scratch/: the home has no "etc"/"a" entry, and
    # scratch has only the seeded "notes" page.
    {:ok, home_schema} = load_schema(mud_ctx.home_room_uuid, ctx.store)
    home_names = home_schema |> Schema.list_entries() |> Enum.map(& &1.name)
    refute "etc" in home_names
    refute "a" in home_names

    {:ok, scratch_dir} = child_dir(mud_ctx.home_room_uuid, "scratch", ctx.store)
    {:ok, scratch_schema} = load_schema(scratch_dir, ctx.store)
    page_names = scratch_schema |> Schema.list_entries() |> Enum.map(& &1.name)
    assert "notes" in page_names
    refute Enum.any?(page_names, &String.contains?(&1, ["/", ".."]))
  end

  test "ENFORCE PIN: a provisioned bot's scratch write LANDS under enforce (cert covers the zoned note)",
       ctx do
    # The whole point of the C3c re-anchor: under REAL enforce + strict trust the
    # zoned note-meta is covered by the bot's {:subtree, home} cert, so the write
    # is authorized and PERSISTS — no more :capability_insufficient. This MUST
    # fail if scratch is anchored off-home or written without the zone stamp.
    prior_gate = Application.get_env(:commonplace, :local_write_gate)
    prior_trust = Application.get_env(:commonplace, :trust)

    on_exit(fn ->
      case prior_gate do
        nil -> Application.delete_env(:commonplace, :local_write_gate)
        v -> Application.put_env(:commonplace, :local_write_gate, v)
      end

      case prior_trust do
        nil -> Application.delete_env(:commonplace, :trust)
        v -> Application.put_env(:commonplace, :trust, v)
      end
    end)

    Application.put_env(:commonplace, :local_write_gate, :enforce)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})

    # Provision + resolve UNDER enforce (node auto-trusted from data_dir; the bot
    # gets its {:subtree, home} cert), then jot.
    {prov, _sc, mud_ctx} = resolve_camillo(ctx)

    assert {:ok, _msg} =
             Scratch.call(%{mud_ctx: mud_ctx}, %{"note" => "landed under enforce"})

    # It actually PERSISTED (not a dry-run false-ok): reconstruct the note and
    # read back the content + the surviving zone stamp.
    {:ok, page_uuid} = page_dir(mud_ctx, "notes")
    {:ok, note_map} = World.get_meta_map(page_uuid, "__note.json", ctx.store)
    assert note_map["text"] =~ "landed under enforce"
    assert note_map["zone"] == prov.home_room_uuid
  end

  # ---- C3d: the DESK (memory + agenda) moved under the home ----

  test "remember: appends an entry to home/memory as a zoned note-meta, bot-signed", ctx do
    {prov, sc, mud_ctx} = resolve_camillo(ctx)

    state = %{mud_ctx: mud_ctx, event: %{"message_id" => "m1"}}
    assert {:ok, "remembered"} = Remember.call(state, %{"text" => "the human likes tea"})

    # Provision already created home/memory; the entry lands in its "entries" log.
    {:ok, mem_uuid} = child_dir(mud_ctx.home_room_uuid, "memory", ctx.store)
    assert mem_uuid == prov.memory_uuid
    {:ok, note_map} = World.get_meta_map(mem_uuid, "__note.json", ctx.store)
    [entry] = note_map["entries"]
    assert entry["text"] == "the human likes tea"
    assert entry["source_msg_id"] == "m1"
    assert is_binary(entry["ts"])

    # Zone inherited == home (a %Struct{} round-trip would have dropped it).
    assert note_map["zone"] == prov.home_room_uuid

    # The append is BOT-signed (the latest commit on the __note.json meta doc).
    bot_signer = Signing.signer_id(sc.identity_uuid, sc.public_key)
    {:ok, meta_uuid} = World.meta_doc_uuid(mem_uuid, "__note.json", ctx.store)
    {:ok, commit} = CommitStore.latest_commit(ctx.store, meta_uuid)
    assert commit.signer_id == bot_signer

    # A second entry, then read_memory reads them back from the home.
    assert {:ok, "remembered"} =
             Remember.call(state, %{"text" => "the human likes coffee"})

    assert {:ok, json} = ReadMemory.call(state, %{})

    assert ["the human likes tea", "the human likes coffee"] =
             json |> Jason.decode!() |> Enum.map(& &1["text"])

    # The contains filter narrows by the "text" field.
    assert {:ok, filtered} = ReadMemory.call(state, %{"contains" => "coffee"})
    assert ["the human likes coffee"] = filtered |> Jason.decode!() |> Enum.map(& &1["text"])
  end

  test "remember/update_agenda without a mud_ctx fail closed (not in the world)", _ctx do
    assert {:error, "You are not in the world."} =
             Remember.call(%{mud_ctx: nil}, %{"text" => "x"})

    assert {:error, "You are not in the world."} =
             UpdateAgenda.call(%{mud_ctx: nil}, %{"text" => "x"})
  end

  test "update_agenda: writes to home/agenda (REPLACE semantics, C5b); Agenda.read reads it back",
       ctx do
    {prov, _sc, mud_ctx} = resolve_camillo(ctx)

    assert Agenda.read(mud_ctx) == []

    assert {:ok, "agenda updated"} =
             UpdateAgenda.call(%{mud_ctx: mud_ctx}, %{"text" => "consolidate the pins"})

    {:ok, agenda_uuid} = child_dir(mud_ctx.home_room_uuid, "agenda", ctx.store)
    assert agenda_uuid == prov.agenda_uuid

    items = Agenda.read(mud_ctx)
    assert Enum.map(items, & &1["text"]) == ["consolidate the pins"]
    assert Enum.all?(items, &is_binary(&1["ts"]))

    # A second call REPLACES rather than accumulating (C5b fixed this from
    # append to replace — see UpdateAgenda's moduledoc).
    assert {:ok, "agenda updated"} =
             UpdateAgenda.call(%{mud_ctx: mud_ctx}, %{"text" => "file the association"})

    assert Enum.map(Agenda.read(mud_ctx), & &1["text"]) == ["file the association"]
  end

  test "ENFORCE PIN: remember LANDS under enforce (cert covers home/memory)", ctx do
    with_enforce(fn ->
      {prov, _sc, mud_ctx} = resolve_camillo(ctx)

      state = %{mud_ctx: mud_ctx, event: %{"message_id" => "m9"}}
      assert {:ok, "remembered"} = Remember.call(state, %{"text" => "landed under enforce"})

      # PERSISTED (not a dry-run false-ok): read the entry + surviving zone stamp
      # back. MUST fail if memory were still in the un-zoned entity dir (denied).
      {:ok, mem_uuid} = child_dir(mud_ctx.home_room_uuid, "memory", ctx.store)
      {:ok, note_map} = World.get_meta_map(mem_uuid, "__note.json", ctx.store)
      assert [%{"text" => "landed under enforce"}] = note_map["entries"]
      assert note_map["zone"] == prov.home_room_uuid
    end)
  end

  test "ENFORCE PIN: update_agenda LANDS under enforce (cert covers home/agenda)", ctx do
    with_enforce(fn ->
      {prov, _sc, mud_ctx} = resolve_camillo(ctx)

      assert {:ok, "agenda updated"} =
               UpdateAgenda.call(%{mud_ctx: mud_ctx}, %{"text" => "file the association"})

      {:ok, agenda_uuid} = child_dir(mud_ctx.home_room_uuid, "agenda", ctx.store)
      {:ok, note_map} = World.get_meta_map(agenda_uuid, "__note.json", ctx.store)
      assert [%{"text" => "file the association"}] = note_map["entries"]
      assert note_map["zone"] == prov.home_room_uuid
    end)
  end

  test "NoteDoc.append_entry round-trip + zone SURVIVES repeated appends", ctx do
    {prov, _sc, mud_ctx} = resolve_camillo(ctx)

    {:ok, dir} =
      NoteDoc.ensure_zoned_dir(mud_ctx.home_room_uuid, "log", ~s({"entries":[]}), mud_ctx)

    assert NoteDoc.read_entries(dir, mud_ctx) == []

    :ok = NoteDoc.append_entry(dir, %{"n" => 1}, mud_ctx)
    :ok = NoteDoc.append_entry(dir, %{"n" => 2}, mud_ctx)

    assert Enum.map(NoteDoc.read_entries(dir, mud_ctx), & &1["n"]) == [1, 2]

    # The node-signed zone stamp is STILL present after two appends.
    {:ok, note_map} = World.get_meta_map(dir, "__note.json", ctx.store)
    assert note_map["zone"] == prov.home_room_uuid
  end

  test "allowlist still governs (C3a): move refused when charter omits it", ctx do
    {_prov, _sc, mud_ctx} = resolve_camillo(ctx)

    # A state whose allowlist grants look/scratch but NOT move.
    state = %{mud_ctx: mud_ctx, allowlist: ["look", "scratch"]}

    assert {:error, "not allowlisted"} =
             Tools.dispatch(state, "move", %{"direction" => "north"})

    # An allowlisted MUD tool dispatches through to the tool.
    assert {:ok, _} = Tools.dispatch(state, "look", %{})
  end

  # Run `fun` under REAL local_write_gate: :enforce + strict trust, restoring
  # the prior config afterward. The node auto-trusts from data_dir, and a
  # provisioned bot gets its {:subtree, home} cert.
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

  defp load_schema(uuid, store), do: Commonplace.MUD.Schemas.load_dir_schema(uuid, store)

  # Resolve the scratchpad page dir (home/scratch/<page>) from the resolved ctx.
  defp page_dir(mud_ctx, page) do
    with {:ok, scratch} <- child_dir(mud_ctx.home_room_uuid, "scratch", mud_ctx.store) do
      child_dir(scratch, page, mud_ctx.store)
    end
  end

  # Look up a named child dir's uuid under `parent`.
  defp child_dir(parent, name, store) do
    with {:ok, schema} <- load_schema(parent, store),
         {:ok, %{node_id: node_id}} <- Schema.get_entry(schema, name) do
      {:ok, node_id}
    end
  end
end

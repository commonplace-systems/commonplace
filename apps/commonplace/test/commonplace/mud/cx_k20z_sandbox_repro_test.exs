defmodule Commonplace.MUD.CxK20zSandboxReproTest do
  @moduledoc """
  CX-k20z — controlled reproduction of the write_meta_doc/merge_meta corruption
  that emptied the live "start" room when open_exit ran through the sandbox.
  DIRECT Facade.open_exit + direct World.merge_meta both SURVIVE (open_exit_test
  green); the live corruption ran open_exit's merge_meta INSIDE run_safe_verb's
  Bounds (spawn_monitor) child. This isolates the sandbox path vs a fresh room.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.MUD.{Schemas, VerbSource, World}
  alias Commonplace.MUD.World.Facade
  alias Commonplace.MUD.Schemas.Room
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_k20z_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"k20z_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"k20z_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"k20z_tss_#{n}",
       pending_imports_name: :"k20z_pi_#{n}"}
    )

    old =
      {Application.get_env(:commonplace, :data_dir), Application.get_env(:commonplace, :trust),
       Application.get_env(:commonplace, :local_write_gate)}

    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    on_exit(fn ->
      {d, t, k} = old
      Application.put_env(:commonplace, :data_dir, d)

      if t,
        do: Application.put_env(:commonplace, :trust, t),
        else: Application.delete_env(:commonplace, :trust)

      if k,
        do: Application.put_env(:commonplace, :local_write_gate, k),
        else: Application.delete_env(:commonplace, :local_write_gate)

      File.rm_rf!(dir)
    end)

    {:ok, node_ctx} = NodeIdentity.signing_context()
    root = UUID.uuid4()

    CommitStore.create_commit(store, root, Encoding.encode_update(Schema.new_schema()), nil, %{},
      signing_context: node_ctx
    )

    commons = mk_room!(store, node_ctx, "The Commons")
    add_dir!(store, root, "commons", commons, node_ctx)

    %{store: store, node_ctx: node_ctx, root: root, commons: commons}
  end

  defp mk_room!(store, sc, name) do
    {:ok, u} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Room{name: name, description: "a place"}),
        store,
        signing_context: sc
      )

    u
  end

  defp add_dir!(store, parent, name, child, sc) do
    {:ok, s} = Schemas.load_dir_schema(parent, store)
    upd = Encoding.encode_update(Schema.add_directory(s, name, child))
    {m, o} = Commonplace.MUD.SignedWrite.opts_for(parent, store: store, signing_context: sc)
    CommitStoreClient.create_chained_commit(store, parent, upd, m, o)
  end

  defp visitor_facade(room, root, store) do
    {pub, priv} = Signing.generate_keypair()
    vctx = %SigningContext{identity_uuid: UUID.uuid4(), public_key: pub, private_key: priv}

    ctx = %{
      signing_context: vctx,
      cert_cids: [],
      signer_id: nil,
      current_room_uuid: room,
      root_uuid: root,
      player_name: "v",
      player_uuid: "vp",
      inventory_uuid: "vi"
    }

    %{Facade.new(ctx, room, [room], {"verbs/x.safe.elx", "owner-x"}, store) | host_kind: :room}
  end

  @fixture Path.join([__DIR__, "..", "..", "fixtures", "cx_k20z_start_meta_precorruption.bin"])

  test "REGRESSION (fixture): the live 'start' pre-corruption CRDT state + write_meta_doc reconstructs INTACT (CX-k20z fix)",
       ctx do
    # The captured 1973-byte CRDT state of the live 'start' room's __room.json
    # (valid 903-char content). PRE-FIX: a single write_meta_doc (delete-all-
    # reinsert) emptied the doc on reconstruct (delete-set over-cover tombstoned
    # the fresh insert). POST-FIX (minimal-diff + pre-commit round-trip verify):
    # the write reconstructs INTACT. The permanent regression pin for the fix.
    state_bin = File.read!(@fixture)
    meta = UUID.uuid4()
    CommitStore.create_commit(ctx.store, meta, state_bin, nil, %{}, signing_context: ctx.node_ctx)

    {:ok, seeded} = Commonplace.Tree.DocBuilder.reconstruct_doc(ctx.store, meta)
    seeded_content = Commonplace.Document.ContentType.get_content(seeded)
    assert seeded_content =~ "Start Room", "fixture must seed valid content"

    # wrap in a dir so we can use get_room, then the elevated-style write.
    dir = UUID.uuid4()
    sch = Schema.add_file(Schema.new_schema(), Schemas.room_filename(), meta)

    {m, o} =
      Commonplace.MUD.SignedWrite.opts_for(dir, store: ctx.store, signing_context: ctx.node_ctx)

    CommitStore.create_commit(ctx.store, dir, Encoding.encode_update(sch), nil, m, o)
    assert {:ok, %Room{name: "The Start Room"}} = World.get_room(dir, ctx.store)

    new_json =
      Jason.encode!(
        Jason.decode!(seeded_content)
        |> Map.update("exits", %{}, &Map.put(&1, "probeexit", ctx.commons))
      )

    :ok = Schemas.write_meta_doc(meta, new_json, ctx.store, signing_context: ctx.node_ctx)

    result = World.get_room(dir, ctx.store)

    IO.puts(
      "\n[k20z FIXTURE] get_room after write_meta_doc => #{inspect(result) |> String.slice(0, 120)}"
    )

    # RED until the write_meta_doc/CRDT fix lands:
    assert {:ok, %Room{name: "The Start Room"}} = result
  end

  test "EMPTY-INITIAL: create meta with EMPTY content, then fill, then re-write (mimics the stub→bootstrap 'start' history)",
       ctx do
    # the live "start" meta history was: commit len=0 (empty stub) → len=903 (filled)
    # → refilled. Reproduce that structure: create_meta_doc with EMPTY text, then
    # write_meta_doc the full content, then write again.
    {:ok, meta} = Schemas.create_meta_doc("", ctx.store, signing_context: ctx.node_ctx)
    dir = UUID.uuid4()
    {:ok, sch} = {:ok, Schema.new_schema()}
    sch = Schema.add_file(sch, Schemas.room_filename(), meta)

    {m, o} =
      Commonplace.MUD.SignedWrite.opts_for(dir, store: ctx.store, signing_context: ctx.node_ctx)

    CommitStore.create_commit(ctx.store, dir, Encoding.encode_update(sch), nil, m, o)

    r1 =
      Schemas.encode_room(%Room{
        name: "The Start Room",
        description: "A snug antechamber — worn — the threshold.",
        exits: %{"north" => ctx.commons}
      })

    :ok = Schemas.write_meta_doc(meta, r1, ctx.store, signing_context: ctx.node_ctx)
    assert {:ok, %Room{name: "The Start Room"}} = World.get_room(dir, ctx.store)

    r2 =
      Schemas.encode_room(%Room{
        name: "The Start Room",
        description: "A snug antechamber — worn smooth — the threshold.",
        exits: %{"north" => ctx.commons, "south" => ctx.commons}
      })

    :ok = Schemas.write_meta_doc(meta, r2, ctx.store, signing_context: ctx.node_ctx)

    result = World.get_room(dir, ctx.store)

    IO.puts(
      "\n[k20z empty-initial] get_room after refill => #{inspect(result) |> String.slice(0, 140)}"
    )

    assert {:ok, %Room{name: "The Start Room"}} = result
  end

  test "MINIMAL: two write_meta_doc delete-all-reinsert calls under the SAME funnel hand (signer_id nil) corrupts",
       ctx do
    room = mk_room!(ctx.store, ctx.node_ctx, "Seeded")
    {:ok, meta} = World.meta_doc_uuid(room, Schemas.room_filename(), ctx.store)

    # write #1 under the FUNNEL hand (signer_id: nil → for_doc(uuid)) — mimics
    # bootstrap merge_exits/write_room (write_meta_doc with no opts).
    :ok =
      Schemas.write_meta_doc(
        meta,
        Schemas.encode_room(%Room{
          name: "Seeded",
          description: "d1",
          exits: %{"north" => ctx.commons}
        }),
        ctx.store,
        signing_context: ctx.node_ctx
      )

    assert {:ok, %Room{description: "d1"}} = World.get_room(room, ctx.store)

    # write #2 under the SAME FUNNEL hand — mimics open_exit's elevated merge_meta.
    :ok =
      Schemas.write_meta_doc(
        meta,
        Schemas.encode_room(%Room{
          name: "Seeded",
          description: "d2",
          exits: %{"north" => ctx.commons, "south" => ctx.commons}
        }),
        ctx.store,
        signing_context: ctx.node_ctx
      )

    result = World.get_room(room, ctx.store)

    IO.puts(
      "\n[k20z minimal] get_room after 2nd funnel write => #{inspect(result) |> String.slice(0, 140)}"
    )

    assert {:ok, %Room{description: "d2"}} = result
  end

  test "ACCUMULATED: N repeated funnel-hand write_meta_doc calls — at what N does it corrupt?",
       ctx do
    room = mk_room!(ctx.store, ctx.node_ctx, "Seeded")
    {:ok, meta} = World.meta_doc_uuid(room, Schemas.room_filename(), ctx.store)

    first_bad =
      Enum.reduce_while(1..30, nil, fn i, _ ->
        desc = "description number #{i} — with an em-dash and some length to it, iteration #{i}."

        :ok =
          Schemas.write_meta_doc(
            meta,
            Schemas.encode_room(%Room{
              name: "Seeded",
              description: desc,
              exits: %{"north" => ctx.commons}
            }),
            ctx.store,
            signing_context: ctx.node_ctx
          )

        case World.get_room(room, ctx.store) do
          {:ok, %Room{description: ^desc}} ->
            {:cont, nil}

          other ->
            IO.puts(
              "[k20z accum] CORRUPTED at write ##{i}: #{inspect(other) |> String.slice(0, 100)}"
            )

            {:halt, i}
        end
      end)

    IO.puts(
      "\n[k20z accum] first corrupting write = #{inspect(first_bad)} (nil = survived all 30)"
    )

    assert is_nil(first_bad), "corrupted at write #{inspect(first_bad)}"
  end

  test "SANDBOX: open_exit run THROUGH run_safe_verb on a FRESH curated room — corrupts?", ctx do
    source = mk_room!(ctx.store, ctx.node_ctx, "The Puzzle Chamber")
    add_dir!(ctx.store, ctx.root, "puzzle", source, ctx.node_ctx)

    body = "Commonplace.MUD.World.Facade.open_exit(world, \"north\", \"#{ctx.commons}\")"

    :ok =
      VerbSource.save_safe_verb(source, "reveal", body, [source], ctx.store,
        signing_context: ctx.node_ctx
      )

    facade = visitor_facade(source, ctx.root, ctx.store)
    res = VerbSource.run_safe_verb(source, "reveal", [source], facade, %{}, ctx.store)
    IO.puts("\n[k20z fresh] run_safe_verb => #{inspect(res)}")

    gr = World.get_room(source, ctx.store)

    IO.puts(
      "[k20z fresh] get_room after sandbox open_exit => #{inspect(gr) |> String.slice(0, 140)}"
    )

    assert {:ok, %Room{exits: exits}} = gr
    assert exits["north"] == ctx.commons
  end

  test "NON-DEGENERACY GUARD: a write with NO shared prefix/suffix anchor is REFUSED, never full-deletes",
       ctx do
    # write_meta_doc's safety rests on a live prefix/suffix anchor (JSON always
    # shares {"…"}). If a future content shape shares NOTHING with the current on
    # a non-empty doc, the minimal-diff would degenerate to delete_text(0,len) =
    # the CX-k20z bug — so it must REFUSE loudly, not silently full-delete.
    {:ok, meta} =
      Schemas.create_meta_doc("aaa-first-content-here", ctx.store, signing_context: ctx.node_ctx)

    # a replacement sharing no prefix (a≠z) and no suffix (e≠!) with the current:
    assert {:error, :meta_write_no_anchor} =
             Schemas.write_meta_doc(meta, "zzz-totally-different!", ctx.store,
               signing_context: ctx.node_ctx
             )

    # the original content is UNTOUCHED (refused before any write).
    {:ok, doc} = Commonplace.Tree.DocBuilder.reconstruct_doc(ctx.store, meta)
    assert Commonplace.Document.ContentType.get_content(doc) == "aaa-first-content-here"
  end
end

defmodule Commonplace.MUD.CxAvzpPrivateRoomTest do
  @moduledoc """
  CX-avzp (P1) — private-room privacy bypass: a visitor forbidden to ENTER a
  `:capability_gated` room still ended up PRESENT inside it and eavesdropped on
  `say`/broadcasts, because the movement verbs relocated the `.usr` presence
  UNCONDITIONALLY (only the later RENDER was read-gated — cosmetic after the
  fact). The presence move subscribes the session to the room's event stream
  (`PlayerSession.handle_verb_result({:moved})` → `Topics.subscribe_room`), so
  the intruder was on the room's PubSub topic + counted in occupancy.

  The fix routes EVERY presence-move vector — `do_go`, `do_teleport`, and the
  citizen-verb `Facade.move_self` (the plan's "future 3rd mover") — through the
  single read-gated chokepoint `World.move_presence/5`, which denies the move
  ATOMICALLY on `Trust.Read.authorized?` = `{:error, :read_denied}` (no
  presence write, no depart/arrive broadcast, and — because subscribe is
  structurally downstream of `{:moved}` — no subscription = no eavesdrop).

  ## The EAVESDROP PIN is non-vacuous (plan-required)

  The `do_teleport` scenario first proves, as a CONTROL, that the stranger DOES
  hear the owner's `say` while legitimately co-located in a PUBLIC room (the
  subscribe + say + PubSub plumbing genuinely works). Only THEN does it show
  that after a refused entry into the private room the same owner's `say` is
  NOT delivered — so the silence is the fix, not broken plumbing.

  ## Harness

  Signed sessions with an OBSERVABLE read gate need `accept_unsigned: false`
  (`with_strict_trust`) — `Trust.reader_authorized?` short-circuits `true`
  under the default `accept_unsigned` posture, so a denial is otherwise
  unobservable. The WRITE gate stays at its default (`:dry_run`) so the
  sessions' own unsigned bootstrap writes (player dir/presence/inventory) still
  land; the READ gate (`Trust.Read.authorized?`, consulted directly by
  `World.move_presence` + `room_snapshot`) is independent of the write knob.
  (Mirrors `Commonplace.MUD.RoomVisibilityTest`'s PlayerSession block.)
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.MUD.{Schemas, World}
  alias Commonplace.MUD.PlayerSession
  alias Commonplace.MUD.Schemas.Room
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  # ---- shared strict-trust env (accept_unsigned: false) ----

  defp with_strict_trust(dir) do
    old_data_dir = Application.get_env(:commonplace, :data_dir)
    old_trust = Application.get_env(:commonplace, :trust)

    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})

    on_exit(fn ->
      restore = fn key, v ->
        if is_nil(v), do: Application.delete_env(:commonplace, key), else: Application.put_env(:commonplace, key, v)
      end

      restore.(:data_dir, old_data_dir)
      restore.(:trust, old_trust)
    end)

    :ok
  end

  defp fresh_ctx do
    {pub, priv} = Signing.generate_keypair()
    %SigningContext{identity_uuid: UUID.uuid4(), public_key: pub, private_key: priv}
  end

  # ---- World.move_presence/5 gate (unit — the chokepoint decision) ----

  describe "World.move_presence/5 read gate" do
    setup do
      dir = Path.join(System.tmp_dir!(), "cp_avzp_gate_#{:rand.uniform(1_000_000_000)}")
      File.mkdir_p!(dir)
      store = :"avzp_gate_store_#{:rand.uniform(1_000_000_000)}"
      start_supervised!({CommitStore, data_dir: dir, name: store})
      on_exit(fn -> File.rm_rf!(dir) end)
      with_strict_trust(dir)
      %{store: store}
    end

    defp mint_room(store, room) do
      {:ok, dir_uuid} = Schemas.create_dir_with_meta(Schemas.room_filename(), Schemas.encode_room(room), store)
      dir_uuid
    end

    test "a gated dest DENIES a stranger viewer BEFORE any move (no presence needed)", %{store: store} do
      owner = fresh_ctx()
      src = mint_room(store, %Room{name: "Src", description: "."})

      dest =
        mint_room(store, %Room{
          name: "Den",
          description: "Private.",
          owner: owner.identity_uuid,
          visibility: :capability_gated
        })

      assert {:error, :read_denied} =
               World.move_presence("player-uuid", "stranger.usr", src, dest,
                 store: store,
                 viewer: "stranger-id"
               )
    end

    test "a gated dest PASSES the gate for the OWNER viewer (delegates to move, not :read_denied)",
         %{store: store} do
      owner = fresh_ctx()
      src = mint_room(store, %Room{name: "Src", description: "."})

      dest =
        mint_room(store, %Room{
          name: "Den",
          description: "Private.",
          owner: owner.identity_uuid,
          visibility: :capability_gated
        })

      # No presence seeded in `src`, so `move` fails downstream — but the point
      # is the OWNER cleared the READ gate: the result is NOT :read_denied.
      result = World.move_presence("player-uuid", "owner.usr", src, dest, store: store, viewer: owner.identity_uuid)
      refute result == {:error, :read_denied}
    end

    test "a PUBLIC dest passes the gate for ANY viewer incl. nil (no-regression)", %{store: store} do
      src = mint_room(store, %Room{name: "Src", description: "."})
      dest = mint_room(store, %Room{name: "Commons", description: "Open."})

      refute World.move_presence("p", "x.usr", src, dest, store: store, viewer: "stranger-id") == {:error, :read_denied}
      refute World.move_presence("p", "x.usr", src, dest, store: store, viewer: nil) == {:error, :read_denied}
    end

    test "an UNREADABLE dest (no room meta) fails OPEN — never a privacy bypass, preserves do_go",
         %{store: store} do
      src = mint_room(store, %Room{name: "Src", description: "."})
      # A random uuid with no room doc: privacy is DEFINED by readable meta, so
      # this cannot be :capability_gated → the gate must not deny.
      refute World.move_presence("p", "x.usr", src, UUID.uuid4(), store: store, viewer: "stranger-id") ==
               {:error, :read_denied}
    end
  end

  # ---- end-to-end eavesdrop pin, via PlayerSession ----

  describe "eavesdrop pin (PlayerSession)" do
    setup do
      Application.ensure_all_started(:phoenix_pubsub)

      case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      dir = Path.join(System.tmp_dir!(), "cp_avzp_e2e_#{:rand.uniform(1_000_000_000)}")
      File.mkdir_p!(dir)
      store = :"avzp_e2e_store_#{:rand.uniform(1_000_000_000)}"
      start_supervised!({CommitStore, data_dir: dir, name: store})
      on_exit(fn -> File.rm_rf!(dir) end)

      case GenServer.whereis(Commonplace.Green.Bursar) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end

      root_uuid = UUID.uuid4()

      {:ok, bursar_pid} =
        Commonplace.Green.Bursar.start_link(root_uuid: root_uuid, store: store, sweep_interval: 60_000)

      on_exit(fn -> if Process.alive?(bursar_pid), do: GenServer.stop(bursar_pid) end)

      update = Encoding.encode_update(Schema.new_schema())
      CommitStore.create_commit(store, root_uuid, update, nil)

      with_strict_trust(dir)

      owner_ctx = fresh_ctx()

      {:ok, public_uuid} =
        Schemas.create_dir_with_meta(
          Schemas.room_filename(),
          Schemas.encode_room(%Room{name: "The Commons", description: "Open to all."}),
          store
        )

      {:ok, private_uuid} =
        Schemas.create_dir_with_meta(
          Schemas.room_filename(),
          Schemas.encode_room(%Room{
            name: "Owner's Den",
            description: "Cozy and private.",
            owner: owner_ctx.identity_uuid,
            visibility: :capability_gated
          }),
          store
        )

      %{
        store: store,
        root: root_uuid,
        owner_ctx: owner_ctx,
        public_uuid: public_uuid,
        private_uuid: private_uuid
      }
    end

    defp start_player(name, ctx, opts) do
      parent = self()
      output_fn = fn text -> send(parent, {:out, name, text}) end

      {:ok, session} =
        PlayerSession.start_link(
          Keyword.merge(
            [player_name: name, root_uuid: ctx.root, store: ctx.store, output_fn: output_fn, owner_pid: parent],
            opts
          )
        )

      drain(name)
      session
    end

    defp drain(name, acc \\ []) do
      receive do
        {:out, ^name, text} -> drain(name, [text | acc])
      after
        40 -> Enum.reverse(acc)
      end
    end

    defp send_input(session, text) do
      PlayerSession.input_sync(session, text)
      Process.sleep(60)
    end

    defp presence_in_room?(room_uuid, presence_filename, store) do
      case Schemas.load_dir_schema(room_uuid, store) do
        {:ok, schema} -> Enum.any?(Schema.list_entries(schema), fn e -> e.name == presence_filename end)
        _ -> false
      end
    end

    test "CONTROL + PIN: stranger hears a say when co-located, but NOT after a refused @teleport into the private room",
         ctx do
      owner = start_player("owner", ctx, signing_context: ctx.owner_ctx, spawn_room_uuid: ctx.public_uuid)
      stranger_ctx = fresh_ctx()
      stranger = start_player("stranger", ctx, signing_context: stranger_ctx, spawn_room_uuid: ctx.public_uuid)

      # --- CONTROL (non-vacuity): both in the PUBLIC room; stranger hears owner ---
      send_input(owner, "say hello-neighbours")
      control = drain("stranger") |> Enum.join("\n")
      assert control =~ "hello-neighbours", "plumbing check: a co-located say must reach the stranger"

      # owner enters their OWN private room (authorized → move + subscribe)
      send_input(owner, "@teleport #{ctx.private_uuid}")
      drain("owner")
      assert presence_in_room?(ctx.private_uuid, "owner.usr", ctx.store), "owner should be admitted to their own room"

      # --- stranger is REFUSED at the door (atomic deny) ---
      send_input(stranger, "@teleport #{ctx.private_uuid}")
      refused = drain("stranger") |> Enum.join("\n")
      assert refused =~ "That place is private."

      refute presence_in_room?(ctx.private_uuid, "stranger.usr", ctx.store),
             "PRESENCE LEAK: refused stranger must NOT be present in the private room"

      # --- THE EAVESDROP PIN: owner speaks a secret inside; stranger hears NOTHING ---
      send_input(owner, "say the combination is seven-three-nine")
      leaked = drain("stranger") |> Enum.join("\n")

      refute leaked =~ "seven-three-nine",
             "EAVESDROP LEAK: a refused stranger received the private room's say"

      refute leaked =~ "combination"
    end

    test "BEAD REPRO (do_go): stepping through a `down` exit into a private room is refused + no eavesdrop",
         ctx do
      # Re-mint the public room with a `down` exit → the private room (the exact
      # black-box vector: a public room adjacent to a private one).
      {:ok, staging_uuid} =
        Schemas.create_dir_with_meta(
          Schemas.room_filename(),
          Schemas.encode_room(%Room{
            name: "Tinker's Loft",
            description: "A public workshop.",
            exits: %{"down" => ctx.private_uuid}
          }),
          ctx.store
        )

      owner = start_player("owner", ctx, signing_context: ctx.owner_ctx, spawn_room_uuid: ctx.private_uuid)
      stranger_ctx = fresh_ctx()
      stranger = start_player("scout", ctx, signing_context: stranger_ctx, spawn_room_uuid: staging_uuid)

      send_input(stranger, "down")
      refused = drain("scout") |> Enum.join("\n")
      assert refused =~ "That place is private."

      refute presence_in_room?(ctx.private_uuid, "scout.usr", ctx.store),
             "PRESENCE LEAK: refused scout must NOT land in the private room via the exit"

      send_input(owner, "say vault code is four-four-two")
      leaked = drain("scout") |> Enum.join("\n")
      refute leaked =~ "four-four-two", "EAVESDROP LEAK: refused scout received the private room's say"
    end
  end
end

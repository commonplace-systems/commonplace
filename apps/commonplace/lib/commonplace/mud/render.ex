defmodule Commonplace.MUD.Render do
  @moduledoc """
  Rendering for MUD verbs — extracted verbatim from
  `Commonplace.MUD.Verbs` per CX-ud1u (the rendering half; the noun/scope
  resolution half was extracted first, see `Commonplace.MUD.Resolver`).

  The formatting surface between world state and player-visible text:
  given already-resolved entries/objects/players (or a uuid to read
  state from), turn them into the strings a verb's `{:reply, _}` /
  `{:error, _}` carries. Nothing here mutates state or dispatches a
  verb — callers (mostly `Commonplace.MUD.Verbs`) resolve the target
  first (via `Commonplace.MUD.Resolver`), then hand it here to render.
  """

  alias Commonplace.MUD.{Resolver, Schemas, World}
  alias Commonplace.MUD.Schemas.{Object, Player, Room}

  # CX-ivqz (read-scoping P2): the in-world `look` renderer gates through
  # the SAME `World.room_snapshot/4` check as the UI pane (Seam 2.1) — a
  # `capability_gated` room refused to this viewer renders "That place is
  # private." instead of leaking name/desc/exits/contents/occupants (Z1/Z2).
  # Field-shape kept identical to the pre-P2 rendering (exits
  # direction-only, sorted; contents/occupants are name lists) so a
  # PUBLIC room's `look` output is byte-for-byte unchanged (no-regression).
  @doc "Render the current room (name/desc/exits/contents/occupants) for `look`."
  def render_room(ctx) do
    case World.room_snapshot(ctx.current_room_uuid, ctx.presence_filename, ctx.store,
           viewer: Commonplace.MUD.Verbs.taker_identity(ctx)
         ) do
      {:ok, %{name: name, desc: desc, exits: exits, contents: objects, occupants: players}} ->
        exit_dirs = exits |> Enum.map(fn {dir, _to} -> dir end)

        IO.iodata_to_binary([
          "== ",
          name,
          " ==\n",
          desc,
          "\n",
          if(exit_dirs == [],
            do: "Exits: (none)\n",
            else: ["Exits: ", Enum.join(exit_dirs, ", "), "\n"]
          ),
          if(objects == [], do: "", else: ["You see: ", Enum.join(objects, ", "), "\n"]),
          if(players == [], do: "", else: ["Players: ", Enum.join(players, ", "), "\n"])
        ])

      {:error, :read_denied} ->
        "That place is private."

      {:error, _} ->
        "(this place has no description)"
    end
  end

  # CX-82wi — `where`: a non-builder QoL that surfaces the CURRENT room's own
  # uuid (its address). A room with no inbound exits — every player's home! —
  # otherwise has an UNLEARNABLE uuid: @dump only printed exit-target + owner
  # uuids, never the room's own, so you could not @link anything to your home,
  # @teleport back to it, or hand its address to a friend. `where` (and the
  # self-uuid now added to `@dump here`) close that gap. Read-only, no auth.
  @doc "Format the current room's own uuid + name for `where`."
  def do_where(ctx) do
    name =
      case World.get_room(ctx.current_room_uuid, ctx.store) do
        {:ok, %Room{name: n}} when is_binary(n) and n != "" -> n
        _ -> "here"
      end

    {:reply,
     "You are in #{name}.\n" <>
       "uuid: #{ctx.current_room_uuid}\n" <>
       "(use this with @link <dir> <uuid> / @teleport <uuid>, or share it so others can link here)"}
  end

  # CX-cj3t.8 (safe half) — a container is LOCKED iff its freeform state
  # submap has state["locked"] == true (composes with put_state: a key-verb
  # flips it via put_state(world, "locked", false)). Strict true; any other
  # value = unlocked (fail-open — a gameplay gate, not a security boundary;
  # the real gate is write-access, which a non-owner lacks). No new Facade
  # primitive, no schema change.
  #
  # HONESTY (plan #6009): a locked container "hides" its contents ONLY
  # in-game (the `look in` command refuses). This is NOT confidentiality —
  # the container's dir/contents sync as CRDT data, so a peer syncing that
  # subtree reads the contents from the raw substrate regardless of the
  # lock. Gameplay gate, not secrecy; do NOT build hidden-info mechanics on
  # it. And "a key = a granted verb that put_states locked=false" works for
  # the OWNER + co-builders granted chest-write (put_state is
  # write_guarded([chest]) = intersection), NOT an arbitrary VISITOR —
  # visitor-usable keys are the deferred setuid / before_get-hook tiers
  # (CX-spyc / the high-trust hook bead).
  @doc "Is `container_uuid`'s freeform state[\"locked\"] == true?"
  def container_locked?(container_uuid, store) do
    case World.get_meta_map(container_uuid, Schemas.object_filename(), store) do
      {:ok, %{"state" => %{"locked" => true}}} -> true
      _ -> false
    end
  end

  # CX-uwam — a container may declare state["lock_key"] = "<item name>". The
  # builtin get/put-from-container then requires the TAKER to HOLD a matching
  # item, evaluated against THEIR OWN inventory — a PER-PLAYER key gate
  # (unlike the global `locked` flag). AIRTIGHT: do_get_from is the sole
  # container-extract path (plan #6087 verified — transfer/3 is put-only,
  # source server-fixed to the invoker), so there's no verb-authoring bypass.
  # HONESTY LIMIT: NAME-matched, so a player who can mint+name an item forges
  # the key — this closes the BYPASS (the theater bug), it is NOT tamper-proof
  # (unforgeable/provenance keys ride the before_get-hook tier). Low-trust:
  # declarative attr + a builtin actor-inventory check, no author code, same
  # class as the `locked` flag.
  @doc "Read `container_uuid`'s declared state[\"lock_key\"], if any."
  def container_lock_key(container_uuid, store) do
    case World.get_meta_map(container_uuid, Schemas.object_filename(), store) do
      {:ok, %{"state" => %{"lock_key" => key}}} when is_binary(key) and key != "" -> {:ok, key}
      _ -> :none
    end
  end

  # CX-hbbi — a container reads as SEALED (contents hidden on look) when the
  # `locked` flag is set OR it declares a lock_key. Command-layer gameplay
  # hiding only (plan #6087) — NOT confidentiality; the doc stays readable
  # directly (real read-secrecy = read-scoping, absent today). Good for a
  # puzzle, do not imply secrecy.
  @doc "Should `container_uuid`'s contents be hidden from `look`/`look in`?"
  def container_sealed?(container_uuid, store) do
    container_locked?(container_uuid, store) or
      match?({:ok, _}, container_lock_key(container_uuid, store))
  end

  @doc "Format a container's contents as a name list, or an empty-container note."
  def render_container_contents(container_uuid, container_name, ctx) do
    items =
      World.list_objects_in(container_uuid, ctx.store)
      |> Enum.map(fn e ->
        case Schemas.load_object(e.node_id, ctx.store) do
          {:ok, %Object{name: name}} -> name
          _ -> e.name |> String.replace_suffix(".obj", "")
        end
      end)

    case items do
      [] -> "The #{container_name} is empty."
      _ -> "The #{container_name} contains: #{Enum.join(items, ", ")}."
    end
  end

  @doc "Resolve+render `look in <container>`'s contents (or a sealed/error note)."
  def do_look_in_container(argv, ctx) do
    container_phrase = Enum.join(argv, " ")

    case Resolver.resolve_container(
           container_phrase,
           [ctx.inventory_uuid, ctx.current_room_uuid],
           ctx
         ) do
      {:ok, container_entry, %Object{} = container_obj} ->
        # CX-hbbi — sealed (locked OR key-gated) hides contents on look.
        if container_sealed?(container_entry.node_id, ctx.store) do
          {:error, "The #{container_obj.name} is sealed."}
        else
          {:reply, render_container_contents(container_entry.node_id, container_obj.name, ctx)}
        end

      {:error, {:not_a_container, name}} ->
        {:error, "You can't look inside the #{name}."}

      {:error, :not_found} ->
        {:error, "You don't see \"#{container_phrase}\" here."}
    end
  end

  # CX-cj3t.1.1: plain "look <obj>" on a container renders its contents
  # instead of the description; a non-container object keeps the old
  # name+description behavior unchanged.
  @doc "Classify+render an already-resolved `look <target>` entry."
  def render_looked_at_entry(entry, phrase_label, ctx) do
    case Resolver.resolve_entry(entry, ctx) do
      {:ok, :object, %Object{container?: true} = obj} ->
        # CX-hbbi — a sealed container hides its contents on plain `look`
        # too (not just `look in`) — no spoiling the box through the door.
        if container_sealed?(entry.node_id, ctx.store) do
          {:reply, "The #{obj.name} is sealed."}
        else
          {:reply, render_container_contents(entry.node_id, obj.name, ctx)}
        end

      {:ok, :object, %Object{} = obj} ->
        {:reply, "#{obj.name}\n#{obj.description}"}

      {:ok, :player, %Player{} = pl} ->
        title = if pl.title == "", do: pl.name, else: pl.title
        {:reply, "#{title}\n#{pl.description}"}

      :not_found ->
        {:error, "You don't see \"#{phrase_label}\" here."}
    end
  end

  @doc "Classify+render an already-resolved `examine <target>` entry."
  def render_examined_entry(entry, phrase_label, ctx) do
    case Resolver.resolve_entry(entry, ctx) do
      {:ok, :object, %Object{} = obj} ->
        {:reply, examine_object_text(entry.node_id, obj, ctx)}

      {:ok, :player, %Player{} = pl} ->
        title = if pl.title == "", do: pl.name, else: pl.title
        {:reply, "#{title}\n#{pl.description}"}

      :not_found ->
        {:error, "You don't see \"#{phrase_label}\" here."}
    end
  end

  # CX-mxxe / CX-hh70 — casual, player-facing `examine` is name + description
  # ONLY. It deliberately does NOT append the object's freeform `meta["state"]`:
  # that block leaked puzzle answer keys (altar `expect: spark` / `solved: yes`,
  # orrery `charge: N`) to any newcomer just reading a description, and broadcast
  # the per-player actor_ref→name mapping the @verb editor tells builders to key
  # private state on (score:<ref>, forecast:<ref>). Raw state now lives on the
  # builder/debug `@dump <obj>` path (the raw-internals command) instead.
  @doc "Format the casual `examine` text (name + description only, no raw state)."
  def examine_object_text(_uuid, %Object{} = obj, _ctx) do
    "#{obj.name}\n#{obj.description}"
  end

  # Render the object's freeform `meta["state"]` submap (CX-hqk5 — dropped by
  # the typed `Object` struct, so read the raw meta map) as a short block, or
  # "" when there's nothing notable.
  @doc "Format an object's raw freeform meta[\"state\"] block for `@dump` (builder/debug)."
  def notable_state(uuid, store) do
    case World.get_meta_map(uuid, Schemas.object_filename(), store) do
      {:ok, %{"state" => state}} when is_map(state) and map_size(state) > 0 ->
        lines =
          state
          |> Enum.map(fn {k, v} -> "  #{k}: #{format_state_value(v)}" end)
          |> Enum.join("\n")

        "State:\n" <> lines

      _ ->
        ""
    end
  end

  @doc "Format a single state value for `notable_state`'s block."
  def format_state_value(v) when is_binary(v), do: v
  def format_state_value(v), do: inspect(v)

  @doc "Format an already-resolved object's `read` text (state text, description, or a nothing-to-read note)."
  def read_object_text(uuid, %Object{} = obj, ctx) do
    case World.get_meta_map(uuid, Schemas.object_filename(), ctx.store) do
      {:ok, %{"state" => %{"text" => text}}} when is_binary(text) and text != "" ->
        "The #{obj.name} reads: #{text}"

      _ ->
        if is_binary(obj.description) and obj.description != "" do
          "The #{obj.name} reads: #{obj.description}"
        else
          "There's nothing to read on #{obj.name}."
        end
    end
  end
end

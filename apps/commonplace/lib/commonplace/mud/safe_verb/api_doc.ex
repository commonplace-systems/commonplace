defmodule Commonplace.MUD.SafeVerb.ApiDoc do
  @moduledoc """
  CX-hbb2 — GENERATED-FROM-DATA documentation for the safe-verb facade
  surface (`Commonplace.MUD.World.Facade`, as admitted by
  `Commonplace.MUD.SafeVerb.Allowlist.profile().domain_allowed`). This is the
  fix for CX-hn75 (a live discoverability bug): the `@verb`-editor's "Common
  calls" banner used to be hand-maintained prose that silently fell behind
  the allowlist (it omitted `open_exit`, `grant`, `spawn`, `consume`,
  `whisper`, and more). Here the banner is DATA, derived from `entries/0`,
  and `entries/0`'s coverage is pinned equal to the live admit-set by
  `api_doc_test.exs` — any future allowlist change fails that test until this
  map is updated, so the two can never drift again.

  DOCUMENTATION ONLY — this module contributes no admit/reject logic; it
  does not touch `Commonplace.MUD.SafeVerb.Allowlist` or
  `Commonplace.Code.Allowlist` in any way.
  """

  @type entry :: %{sig: String.t(), brief: String.t()}

  # One entry per `{fun, arity}` in `Allowlist.profile().domain_allowed`.
  # `sig` shows the call shape exactly as an author writes it (the literal
  # `world` receiver + named args); `brief` is derived from
  # `Commonplace.MUD.World.Facade`'s own `@doc`/`@spec` for that function —
  # do not paraphrase past what that doc says.
  @entries %{
    # ---- world-structure (reads + navigation) ----
    {:look, 1} => %{
      sig: "look(world)",
      brief: "render the current room (name/description/exits)"
    },
    {:describe, 2} => %{
      sig: "describe(world, target_uuid)",
      brief: "name + description text for any room/object/player uuid"
    },
    {:get_attr, 2} => %{
      sig: "get_attr(world, target_uuid)",
      brief: "raw attribute map (room/object/player metadata) for any target uuid"
    },
    {:move_self, 2} => %{
      sig: "move_self(world, dest_room_uuid)",
      brief:
        "teleport the INVOKER'S OWN presence into a room (portals/trapdoors) — never moves another player"
    },
    {:move_object, 2} => %{
      sig: "move_object(world, dest_room_uuid)",
      brief:
        "move this verb's bound object into a room you can write (room-write intersection; builder-scoped)"
    },
    {:open_exit, 3} => %{
      sig: "open_exit(world, dir, dest_uuid)",
      brief:
        "open a new exit from this room toward a room you may target (add-only, idempotent; trust-gated: source must be yours, dest must be yours or public/curated)"
    },

    # ---- speech / feedback (broadcasts, no doc write) ----
    {:say, 2} => %{
      sig: "say(world, text)",
      brief: "speak text ALOUD in the invoker's current room"
    },
    {:emit, 2} => %{
      sig: "emit(world, event)",
      brief: "broadcast an unattributed custom text event to the room"
    },
    {:emit_action, 3} => %{
      sig: "emit_action(world, first_person, third_person)",
      brief: "broadcast an attributed action — \"You <first_person>\" / \"<name> <third_person>\""
    },
    {:notify, 2} => %{
      sig: "notify(world, text)",
      brief:
        "deliver text PRIVATELY to the invoker only (puzzle STATUS/feedback — not aloud like say)"
    },
    {:whisper, 3} => %{
      sig: "whisper(world, target_name, text)",
      brief:
        "send a private message to a PLAYER in the invoker's current room (rate-limited, same-room-only resolution)"
    },

    # ---- state (freeform per-object data) ----
    {:get_state, 2} => %{
      sig: "get_state(world, key)",
      brief:
        "read freeform per-object state written by put_state (this verb's own bound object only)"
    },
    {:put_state, 3} => %{
      sig: "put_state(world, key, value)",
      brief: "write freeform per-object state (bounded: key ≤ 64 bytes, value ≤ 1024 bytes JSON)"
    },
    {:configure_attr, 4} => %{
      sig: "configure_attr(world, minted_uuid, key, value)",
      brief: "set a metadata attribute on an object THIS RUN minted (own-creation exception)"
    },
    {:configure_state, 4} => %{
      sig: "configure_state(world, minted_uuid, key, value)",
      brief: "write freeform state on an object THIS RUN minted (own-creation exception)"
    },
    {:set_attr, 3} => %{
      sig: "set_attr(world, key, value)",
      brief:
        "DEPRECATED — always drops the write; use put_state for freeform state, builder verbs for typed fields"
    },

    # ---- randomness (cosmetic, no authority) ----
    {:random, 2} => %{
      sig: "random(world, n)",
      brief: "a random integer in 1..n (dice roll)"
    },
    {:pick, 2} => %{
      sig: "pick(world, list)",
      brief: "a random element of a list (nil if empty)"
    },

    # ---- identity (server-set, spoof-proof) ----
    {:actor_name, 1} => %{
      sig: "actor_name(world)",
      brief:
        "the invoker's DISPLAY name (server-set; for narration — use actor_ref for a stable per-player state KEY)"
    },
    {:actor_ref, 1} => %{
      sig: "actor_ref(world)",
      brief:
        "a STABLE opaque per-invoker key for per-player state (survives @name renames; use with put_state)"
    },
    {:actor_carries?, 2} => %{
      sig: "actor_carries?(world, name_or_uuid)",
      brief:
        "does the invoker carry an item matching name/uuid? (own inventory only — gated-content check, e.g. key checks)"
    },

    # ---- inventory / object lifecycle ----
    {:create_child, 2} => %{
      sig: "create_child(world, name)",
      brief: "create a new child object under this verb's bound object"
    },
    {:transfer, 3} => %{
      sig: "transfer(world, item_uuid, dest_container_uuid)",
      brief: "move an item from the invoker's inventory into a container"
    },
    {:spawn, 2} => %{
      sig: "spawn(world, name)",
      brief: "spawn a new object into the invoker's current room (room-write intersection)"
    },
    {:give_to_actor, 2} => %{
      sig: "give_to_actor(world, name)",
      brief:
        "mint a new object directly into the INVOKER's own inventory (reward/give-out; invoker-signed, no owner_grant needed)"
    },
    {:grant, 2} => %{
      sig: "grant(world, name)",
      brief:
        "WORLD REWARD GRANT — node-signed mint into the invoker's inventory, gated to node-owned/curated hosts (anti-farm) + zone-stamped to the recipient (anti-forge)"
    },
    {:consume, 1} => %{
      sig: "consume(world)",
      brief:
        "destroy (unlink) this verb's bound object — from your own inventory, or a room-fixed object you have write authority over"
    },
    {:destroy_child, 2} => %{
      sig: "destroy_child(world, name)",
      brief: "destroy (unlink) a named child of this verb's bound object"
    },
    {:consume_from_inventory, 2} => %{
      sig: "consume_from_inventory(world, name)",
      brief:
        "consume (unlink) a named item from the invoker's OWN inventory (quest turn-in; own-inventory authority only)"
    },
    {:give_from_inventory, 3} => %{
      sig: "give_from_inventory(world, name, recipient_name)",
      brief:
        "give a held item to a SAME-ROOM recipient's inventory (own-item authority; additive, never overwrites)"
    }
  }

  # Stable, deterministic rendering order — grouped by concern, NOT
  # alphabetical or insertion order (both of which drift/reshuffle whenever
  # `@entries` gains a key). Every key in `@entries` MUST appear in exactly
  # one group here; `render_calls/0` asserts total coverage at build time via
  # the module attribute below so a forgotten group assignment fails to
  # compile rather than silently under-rendering.
  @groups [
    {"World / navigation",
     [
       {:look, 1},
       {:describe, 2},
       {:get_attr, 2},
       {:move_self, 2},
       {:move_object, 2},
       {:open_exit, 3}
     ]},
    {"Speech / feedback",
     [
       {:say, 2},
       {:emit, 2},
       {:emit_action, 3},
       {:notify, 2},
       {:whisper, 3}
     ]},
    {"State",
     [
       {:get_state, 2},
       {:put_state, 3},
       {:configure_attr, 4},
       {:configure_state, 4},
       {:set_attr, 3}
     ]},
    {"Randomness", [{:random, 2}, {:pick, 2}]},
    {"Identity", [{:actor_name, 1}, {:actor_ref, 1}, {:actor_carries?, 2}]},
    {"Inventory / objects",
     [
       {:create_child, 2},
       {:transfer, 3},
       {:spawn, 2},
       {:give_to_actor, 2},
       {:grant, 2},
       {:consume, 1},
       {:destroy_child, 2},
       {:consume_from_inventory, 2},
       {:give_from_inventory, 3}
     ]}
  ]

  grouped_keys = @groups |> Enum.flat_map(fn {_label, keys} -> keys end) |> MapSet.new()
  entry_keys = @entries |> Map.keys() |> MapSet.new()

  if not MapSet.equal?(grouped_keys, entry_keys) do
    raise "Commonplace.MUD.SafeVerb.ApiDoc: @groups and @entries have drifted apart " <>
            "(missing from groups: #{inspect(MapSet.difference(entry_keys, grouped_keys))}, " <>
            "stale in groups: #{inspect(MapSet.difference(grouped_keys, entry_keys))})"
  end

  @doc "The `{fun, arity} => %{sig:, brief:}` map — one entry per admitted facade call."
  @spec entries() :: %{{atom(), non_neg_integer()} => entry()}
  def entries, do: @entries

  @doc """
  The "Common calls" text block for the `@verb` editor banner, GENERATED from
  `entries/0` (never hand-maintained prose — see the moduledoc). Grouped by
  concern in a stable, deterministic order.
  """
  @spec render_calls() :: String.t()
  def render_calls do
    @groups
    |> Enum.map(fn {label, keys} ->
      lines =
        keys
        |> Enum.map(fn key ->
          %{sig: sig, brief: brief} = Map.fetch!(@entries, key)
          "  " <> sig <> " — " <> brief
        end)
        |> Enum.join("\n")

      label <> ":\n" <> lines
    end)
    |> Enum.join("\n")
  end
end

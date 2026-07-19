defmodule Commonplace.Bots.Worker.Tools.Dig do
  @moduledoc """
  `dig` tool (Camillo C6, cp-plan #8949/#8952) — carve a new room from
  where the bot is standing, bot-signed, through the SAME write-core a
  human builder's `@dig` and `Commonplace.Bots.Citizen`'s own foyer/study
  seeding use.

  "dig -> walk in -> describe" is the whole design: this tool starts the
  new room UNDESCRIBED (`"(no description yet)"`,
  `Commonplace.MUD.Build.dig_room/4`'s own genesis text) — composing what
  belongs there is `describe`'s job, not this tool's. `dig` only carves
  the door and the room behind it.

  ## MECHANICS: the SAME write-core Citizen.provision uses

  `Commonplace.MUD.Build.dig_room/4` mints the new room as a ZONED CHILD
  of the bot's HOME (never nested under wherever the bot happens to be
  standing — `Citizen`'s own foyer/study are both direct children of home,
  connected by exit edges, not tree nesting; see that module's moduledoc)
  via `ChildMutation.create_zoned_child`, inheriting the home zone-stamp,
  PLUS the reciprocal exit baked into the new room's genesis JSON and the
  forward exit merged onto the CURRENT room via `Build.update_room_exit/4`
  (surgical `merge_meta`, never a struct round-trip — CX-cl65). Every write
  is bot-signed via `Build.write_opts/1` (`ctx`'s own signing_context /
  cert_cids / signer_id) except the new room's zone-stamp genesis itself,
  which is NODE-signed by construction (CX-4u03 split authority) — the
  identical signing split every other C3c/C5b/C5c build/write tool has.

  ## FAIL-CLOSED ON COLLISION (mirrors `Verbs.do_dig_write/4` exactly — CX-p0wx)

  An existing exit in the requested direction refuses HONESTLY, BEFORE any
  write is attempted — never a silent overwrite that strands the old
  target room unreachable. The exact same check `@dig`'s human-facing verb
  makes (`World.get_room/2` on the CURRENT room, `Map.fetch(exits,
  direction)`), so a bot digging behaves exactly like a human builder
  digging: no parallel, weaker collision rule.

  ## SCOPE: home zone only, enforced TWICE (mirrors `describe` exactly)

  Two independent layers refuse a dig from outside the bot's own home zone:

    * **(belt) the TOOL check**, BEFORE any write: the CURRENT room's
      carried zone-stamp (`Trust.doc_zone/2` — the SAME predicate the
      trust carve itself uses) must equal `ctx.home_room_uuid`. A mismatch
      refuses with a sanitized message and performs NO write, even under a
      permissive local write gate. This matters even though the NEW
      room's mint is always home-anchored regardless: the OTHER write,
      `Build.update_room_exit/4`'s merge onto the CURRENT room, targets
      wherever the bot is actually standing — without this check, digging
      from a foreign (non-home) room would attempt to graft an exit edge
      onto a room the bot doesn't own, silently succeeding under a
      permissive gate.
    * **(suspenders) the write-gate**, downstream, under
      `local_write_gate: :enforce`: even bypassing the tool check (a
      direct `Build.dig_room/4` call from a foreign room), the bot's
      `{:subtree, home}` cert doesn't cover a non-home room's exit-merge
      write, and the write-gate denies it.

  Pinned separately (`dig_test.exs`), the same discipline `describe_test
  .exs` established.

  ## Direction validation

  Reuses `Commonplace.MUD.Parser.direction?/1` / `opposite_direction/1` —
  the SAME direction vocabulary `@dig`/`move` already use (no parallel
  direction list to drift out of sync).

  ## Room-name guard

  Mirrors the scratch/wiki page-name guard: a single safe segment, no `/`,
  `\\`, `..`, empty, or oversized name.
  """

  alias Commonplace.MUD.Build
  alias Commonplace.MUD.Parser
  alias Commonplace.MUD.Schemas.Room
  alias Commonplace.MUD.World
  alias Commonplace.Trust

  @max_name_len 64
  # A single safe segment: alnum plus . _ ' - and spaces. No slashes, no "..".
  @safe_name ~r/^[A-Za-z0-9 ._'-]+$/

  def name, do: "dig"

  def definition do
    %{
      "name" => "dig",
      "description" =>
        "Carve a new room from where you're standing, in a direction (north, south, " <>
          "east, west, up, down, in, out). The new room starts undescribed — walk in " <>
          "and use describe to compose it. Refuses if a door already exists that way, " <>
          "or if you're not in your own home.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "direction" => %{
            "type" => "string",
            "description" => "The direction to dig, e.g. \"north\"."
          },
          "name" => %{
            "type" => "string",
            "description" => "The new room's name."
          }
        },
        "required" => ["direction", "name"]
      }
    }
  end

  def call(%{mud_ctx: ctx}, %{"direction" => direction, "name" => room_name})
      when is_map(ctx) and is_binary(direction) and is_binary(room_name) do
    with {:ok, dir} <- safe_direction(direction),
         {:ok, new_name} <- safe_name(room_name),
         :ok <- check_home_zone(ctx),
         :ok <- check_no_collision(ctx, dir),
         {:ok, _new_room_uuid} <-
           Build.dig_room(ctx, dir, Parser.opposite_direction(dir), new_name) do
      {:ok, "You carve out a new room (#{new_name}). #{String.capitalize(dir)} leads there."}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call(%{mud_ctx: ctx}, _input) when is_map(ctx),
    do: {:error, "dig requires a 'direction' and a 'name'."}

  # No MUD ctx — not in the world, nothing to dig from. Sanitized refusal.
  def call(_state, _input), do: {:error, "You are not in the world."}

  defp safe_direction(direction) do
    dir = direction |> String.trim() |> String.downcase()

    if Parser.direction?(dir) do
      {:ok, dir}
    else
      {:error, "Unknown direction. Try north, south, east, west, up, down, in, or out."}
    end
  end

  defp safe_name(room_name) do
    trimmed = String.trim(room_name)

    cond do
      trimmed == "" -> {:error, "Bad room name."}
      String.length(trimmed) > @max_name_len -> {:error, "Bad room name."}
      trimmed in [".", ".."] -> {:error, "Bad room name."}
      String.contains?(trimmed, ["/", "\\", ".."]) -> {:error, "Bad room name."}
      Regex.match?(@safe_name, trimmed) -> {:ok, trimmed}
      true -> {:error, "Bad room name."}
    end
  end

  # (belt) TOOL-layer scope check, BEFORE any write — see moduledoc "SCOPE".
  defp check_home_zone(ctx) do
    if Trust.doc_zone(ctx.current_room_uuid, ctx.store) == ctx.home_room_uuid do
      :ok
    else
      {:error, "You can only dig from within your own home."}
    end
  end

  # Mirrors Verbs.do_dig_write/4's collision check exactly (CX-p0wx): refuse
  # BEFORE any write if a door already exists that way — never a silent
  # overwrite that strands the old target room unreachable.
  defp check_no_collision(ctx, dir) do
    case World.get_room(ctx.current_room_uuid, ctx.store) do
      {:ok, %Room{exits: exits}} ->
        case Map.fetch(exits, dir) do
          {:ok, _existing_uuid} -> {:error, "There is already a door #{dir}."}
          :error -> :ok
        end

      {:error, _reason} ->
        {:error, "Can't tell what's around you right now."}
    end
  end
end

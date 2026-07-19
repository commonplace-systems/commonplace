defmodule Commonplace.Bots.Worker.Tools.Describe do
  @moduledoc """
  `describe` tool (Camillo C5b, cp-plan #8880) — the bot REWRITES a room's
  description: memory-as-description, the palace's core write primitive.

  Where `scratch`/`remember` grow an append-only log, `describe` is the tool
  that lets the bot DISTILL: choose what belongs on a room's face by rewriting
  it outright. That's the right verb for distilled memory — the bot doesn't
  accumulate description text, it curates it.

  ## SEMANTIC: full REPLACE, not append

  Calling `describe` with `"text"` REPLACES the target room's `"description"`
  field wholesale. There is no append mode here — the whole point of the tool
  is that the bot composes the room's description as a single considered
  statement each time, the way a person redrafts a plaque rather than pasting
  a new line under the old one.

  ## MECHANICS: zone-preserving targeted `merge_meta`, never a struct round-trip

  The write is `World.merge_meta(target_uuid, Schemas.room_filename(),
  %{"description" => text}, ...)` — a SURGICAL single-field merge on the room's
  raw `__room.json`, the same C3c/C3d shape `Commonplace.Bots.NoteDoc` uses for
  the scratchpad. This is the CX-k20z lesson applied here: a `%Room{}` struct
  round-trip (`get_room` → `%{room | description: text}` → `encode_room`) would
  drop every field the typed struct doesn't carry — most importantly the
  node-signed `zone` stamp — and the subtree write-carve would then read
  `zone: home → absent` as a protected-field mutation and DENY the write, even
  for the room's rightful owner. `merge_meta` touches only `"description"` and
  leaves every other key (including `zone`) byte-identical. NEVER swap this for
  a `get_room`/`encode_room` pair.

  Every write is bot-signed via the same `signing_context`/`cert_cids`/
  `signer_id` shape every other C3c/C3d tool threads from `ctx`.

  ## SCOPE: home zone only, enforced TWICE

  Two independent layers refuse a describe outside the bot's own home zone —
  deliberately not just one:

    * **(belt) the TOOL check**, here, BEFORE any write is attempted: the
      resolved target's zone stamp (`Trust.doc_zone/2` — the SAME membership
      predicate the trust carve itself uses, no skew) must equal
      `ctx.home_room_uuid`. A mismatch refuses with a sanitized message and
      performs NO write, even under a permissive local write gate.

    * **(suspenders) the write-gate**, downstream, under
      `local_write_gate: :enforce`: even if the tool check were somehow
      bypassed (a direct `World.merge_meta` call with the bot's ctx against a
      non-home room, as a test might construct to prove the second layer
      independently), the bot's `{:subtree, home}` cert does not cover a
      non-home room, and the write is DENIED by the ordinary subtree carve.

  These two layers are pinned SEPARATELY (`describe_test.exs`) — the tool-layer
  pin proves the refusal happens before any write attempt even permissively;
  the gate-layer pin proves the substrate itself would deny it even if the
  tool-layer check were absent.

  ## Target resolution — home-subtree only, no global resolver

  `"target"` is `"here"` (or omitted) for `ctx.current_room_uuid`, or a room
  name resolved ONLY among the bot's own home + the rooms dug directly under
  it (`Commonplace.MUD.Build.dig_room/4` always mints a citizen's dug rooms as
  DIRECT children of home — see `Commonplace.Bots.Citizen`'s moduledoc: foyer
  and study are both siblings under home, connected by exit edges, not nested).
  This mirrors how `move`/`look` resolve rooms through `World` primitives
  rather than inventing a new global name resolver — matching is
  case-insensitive substring against the room's schema entry key and its own
  `Schemas.Room.name`, the same idiom `World.find_entry_by_name/3` uses. A
  name that resolves outside the home is still caught by the zone belt-check
  above (defense in depth: even a `home`-shaped substree match doesn't skip
  it) — but as a matter of correctness the search space alone never looks
  further than the home.

  ## CAP

  `text` over ~4096 bytes is refused honestly (an "too long" message) with NO
  write attempted — no truncation, no partial write.

  ## v0 scope

  Describe ONLY — no rename, no exits. `@desc`/`PlayerSession`'s existing
  human-facing description-set path is the sibling surface; unifying them is
  future work, not attempted here (both bottom out on the same
  `World.merge_meta` primitive already, so the unification is a call-site
  consolidation, not a design change).
  """

  alias Commonplace.MUD.{Schemas, World}
  alias Commonplace.MUD.Schemas.Room
  alias Commonplace.Trust

  @max_text_bytes 4096

  def name, do: "describe"

  def definition do
    %{
      "name" => "describe",
      "description" =>
        "Rewrite a room's description — the full text, replacing whatever was there. " <>
          "Only rooms in your own home (your home room, or a room you dug under it). " <>
          "Optional \"target\" picks the room by name; omit or use \"here\" for the room " <>
          "you're standing in. Keep it under ~4096 bytes.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "target" => %{
            "type" => "string",
            "description" =>
              "Which room to describe: \"here\" (default) or a room name in your home."
          },
          "text" => %{
            "type" => "string",
            "description" => "The new description, replacing the room's current one."
          }
        },
        "required" => ["text"]
      }
    }
  end

  def call(%{mud_ctx: ctx}, %{"text" => text} = input)
      when is_map(ctx) and is_binary(text) and text != "" do
    with :ok <- check_cap(text),
         {:ok, target_uuid} <- resolve_target(ctx, Map.get(input, "target")),
         :ok <- check_home_zone(ctx, target_uuid),
         :ok <- write_description(ctx, target_uuid, text) do
      {:ok, "described #{room_label(target_uuid, ctx)}"}
    end
  end

  def call(%{mud_ctx: ctx}, _input) when is_map(ctx),
    do: {:error, "describe requires a non-empty 'text'."}

  # No MUD ctx — not in the world, nothing to describe. Sanitized refusal.
  def call(_state, _input), do: {:error, "You are not in the world."}

  # CAP: refuse honestly before resolving anything or touching the store.
  defp check_cap(text) do
    if byte_size(text) > @max_text_bytes do
      {:error, "That description is too long (max #{@max_text_bytes} bytes)."}
    else
      :ok
    end
  end

  # "here" / omitted / blank -> the room the bot is standing in RIGHT NOW
  # (ctx.current_room_uuid, read fresh by Loop.dispatch_tool/2 immediately
  # before THIS call — CX-mpk0, cp-plan #8933/#8934 — never a turn-start
  # snapshot that a prior move in the same turn could have made stale).
  # KEPT as the default target deliberately (cp-plan #8934(d)): with an
  # honestly-fresh position "here" is the right UX — the tool isn't
  # punished for the ctx staleness that used to sit behind it. Anything
  # else is a name, resolved ONLY within the home + its directly-dug rooms.
  defp resolve_target(ctx, target) when target in [nil, ""], do: {:ok, ctx.current_room_uuid}

  defp resolve_target(ctx, target) when is_binary(target) do
    trimmed = String.trim(target)

    cond do
      trimmed == "" or String.downcase(trimmed) == "here" -> {:ok, ctx.current_room_uuid}
      true -> resolve_named_home_room(ctx, trimmed)
    end
  end

  defp resolve_target(_ctx, _other), do: {:error, "Describe what? Name a room, or say \"here\"."}

  defp resolve_named_home_room(ctx, name) do
    needle = String.downcase(name)

    cond do
      matches?(ctx.home_room_uuid, "home", needle, ctx.store) ->
        {:ok, ctx.home_room_uuid}

      true ->
        World.list_entries(ctx.home_room_uuid, ctx.store)
        |> Enum.filter(&(&1.type == :dir))
        |> Enum.find_value(fn entry ->
          if matches?(entry.node_id, entry.name, needle, ctx.store), do: entry.node_id
        end)
        |> case do
          nil -> {:error, "You don't know a room called that in your home."}
          uuid -> {:ok, uuid}
        end
    end
  end

  # A candidate matches when either its schema entry-key or its own Room
  # display name contains the needle, case-insensitively. Only Room-shaped
  # dirs are candidates (a scratch/agenda/memory note-meta dir under home
  # never resolves — it isn't a room at all, World.get_room refuses it).
  defp matches?(uuid, entry_name, needle, store) do
    case World.get_room(uuid, store) do
      {:ok, %Room{name: room_name}} ->
        String.contains?(String.downcase(entry_name || ""), needle) or
          (is_binary(room_name) and String.contains?(String.downcase(room_name), needle))

      _ ->
        false
    end
  end

  # (belt) TOOL-layer scope check, BEFORE any write: the target's carried
  # zone-stamp (Trust.doc_zone/2 — the SAME predicate the write-carve itself
  # uses) must equal the bot's own home. A room dug under home inherits the
  # home zone; the home dir's own zone equals its own uuid (Citizenship
  # stamps it that way at genesis) — so this one equality check covers both
  # "describe here" (home itself or a dug room) and a named lookup uniformly.
  defp check_home_zone(ctx, target_uuid) do
    if Trust.doc_zone(target_uuid, ctx.store) == ctx.home_room_uuid do
      :ok
    else
      {:error, "You can only describe rooms in your own home."}
    end
  end

  defp write_description(ctx, target_uuid, text) do
    case World.merge_meta(
           target_uuid,
           Schemas.room_filename(),
           %{"description" => text},
           ctx.store,
           bot_opts(ctx)
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, inspect(reason)}
      other -> {:error, inspect(other)}
    end
  end

  defp bot_opts(ctx) do
    [
      signing_context: ctx.signing_context,
      cert_cids: ctx.cert_cids,
      signer_id: ctx.signer_id
    ]
  end

  defp room_label(uuid, ctx) do
    case World.get_room(uuid, ctx.store) do
      {:ok, %Room{name: name}} when is_binary(name) and name != "" -> name
      _ -> "the room"
    end
  end
end

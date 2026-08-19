defmodule Commonplace.MUD.Resolver do
  @moduledoc """
  Scope/noun resolution for MUD verbs — extracted verbatim from
  `Commonplace.MUD.Verbs` per CX-ud1u (the god-module split; this is the
  resolver half, rendering extraction is a later pass).

  The single noun→entity resolution surface: given a raw `argv` (or
  phrase) and a set of candidate directories (room/inventory uuids), find
  the schema entry it names and classify what it resolves to (`:object` /
  `:player`).

  ## ctx contract

  Every function here takes the same `ctx` map `Commonplace.MUD.PlayerSession`
  builds for verb dispatch — in particular `ctx.store`, `ctx.inventory_uuid`,
  `ctx.current_room_uuid`, and `ctx.root_uuid` are read by functions in this
  module. Callers pass `ctx` through unchanged; nothing here mutates it.
  """

  alias Commonplace.MUD.{Schemas, World}
  alias Commonplace.MUD.Schemas.{Object, Player}
  alias Commonplace.Tree.Schema

  # CX-8iyv: shared greedy phrase matcher for target-taking verbs
  # (take/drop/look/@dump/@desc/@name/@alias). Tries the longest prefix
  # of `argv` first (down to a single word), searching `dirs` in order
  # for each candidate phrase, so multi-word names/aliases win over
  # shorter partial matches. `min_remainder` reserves that many trailing
  # words (e.g. so `@desc <target> <text>` always leaves at least one
  # word for the text) — the match never consumes more than
  # `length(argv) - min_remainder` words.
  #
  # Returns `{:ok, entry, matched_phrase, remainder_words}` or
  # `:not_found`.
  @doc "Greedy longest-prefix phrase match of `argv` against `dirs`, in order."
  def greedy_match_entry(dirs, argv, store, opts \\ []) do
    min_remainder = Keyword.get(opts, :min_remainder, 0)
    max_len = length(argv) - min_remainder

    if max_len < 1 do
      :not_found
    else
      Enum.reduce_while(max_len..1//-1, :not_found, fn n, _acc ->
        phrase = argv |> Enum.take(n) |> Enum.join(" ")

        case find_entry_in_dirs(phrase, dirs, store) do
          {:ok, entry} -> {:halt, {:ok, entry, phrase, Enum.drop(argv, n)}}
          :error -> {:cont, :not_found}
        end
      end)
    end
  end

  # CX-c6ph — rank by match QUALITY across all dirs (exact-name beats an
  # alias/partial match in an earlier dir), dir order breaking ties
  # (Enum.max_by keeps the first max element, so [inventory, room] still
  # tie-breaks to inventory for equal-quality matches).
  @doc "Rank `phrase` across `dirs`, exact-name beating alias/partial matches."
  def find_entry_in_dirs(phrase, dirs, store) do
    dirs
    |> Enum.map(fn dir -> World.find_entry_ranked(dir, phrase, store) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(fn {s, _} -> s end, fn -> nil end)
    |> case do
      {_score, entry} -> {:ok, entry}
      nil -> :error
    end
  end

  # CX-8iyv: shared helper for @desc/@name/@alias — greedy-match a
  # (possibly multi-word) target against the current room, requiring at
  # least one argv word left over for the text/new-name/new-alias that
  # follows it. "here"/"room" stay single-word literals (never part of a
  # greedy phrase match) so they keep addressing the room itself.
  #
  # CX-df64: also search the actor's INVENTORY (same [inventory, room]
  # precedence `find_verb_in_scope`'s `resolve_target_object` and the
  # other `greedy_match_entry([ctx.inventory_uuid, ctx.current_room_uuid],
  # ...)` call sites use, and the same set `@verb`'s target resolution
  # already searches via its own two-step room-then-inventory fallback in
  # `do_verb_edit_resolved/3`). Previously this only searched the room, so
  # `@desc <carried-object> <text>` on an object you own but are HOLDING
  # (not yet dropped) fell through to the generic "Try: @desc <target>
  # <text>" usage hint as if the syntax itself were wrong, rather than
  # resolving (or refusing) the target.
  @doc "Split `argv` into a matched target phrase and trailing rest-text."
  def split_target_and_rest(argv, ctx) do
    case argv do
      [kw | rest] when kw in ["here", "room"] and rest != [] ->
        {:ok, kw, Enum.join(rest, " ")}

      _ ->
        case greedy_match_entry([ctx.inventory_uuid, ctx.current_room_uuid], argv, ctx.store,
               min_remainder: 1
             ) do
          {:ok, _entry, phrase, remainder} -> {:ok, phrase, Enum.join(remainder, " ")}
          :not_found -> :not_found
        end
    end
  end

  # CX-wkau (MUD-as-documents Inc-1, tranche 1) — PROMOTED verb-authoring
  # surface: the minimal combined greedy-match + type-resolve glue that
  # `do_examine/2` and `do_read/2` both need, exposed so their doc-hosted
  # seeds (`priv/engine_verbs/examine.exs.seed` / `read.exs.seed`) can reach
  # entity resolution WITHOUT the private `greedy_match_entry/4` /
  # `resolve_entry/2` machinery (and its `find_entry_in_dirs/3` ranking/
  # visibility internals) being copied into a doc or made public wholesale.
  # Searches `[ctx.inventory_uuid, ctx.current_room_uuid]` (the fixed
  # precedence every other target-taking builtin uses) for the longest
  # `argv` prefix that names something, then classifies it. Three-way
  # result so a caller can distinguish "nothing named that here at all"
  # (`:not_found`) from "found an entry but it isn't an examinable/readable
  # object or player" (`:unresolved`) — `do_read/2`'s baseline treats those
  # two differently (a bare "don't see it" vs "nothing to read on it"), so
  # collapsing them here would silently change read's behavior.
  @doc "Resolve `argv` to `{uuid, kind, thing}` against inventory-then-room."
  def resolve_target(argv, ctx) do
    case greedy_match_entry([ctx.inventory_uuid, ctx.current_room_uuid], argv, ctx.store) do
      {:ok, entry, _phrase, _remainder} ->
        case resolve_entry(entry, ctx) do
          {:ok, kind, thing} -> {:ok, entry.node_id, kind, thing}
          :not_found -> :unresolved
        end

      :not_found ->
        :not_found
    end
  end

  @doc "Classify a resolved schema entry as `:object` or `:player`."
  def resolve_entry(%Schema.Entry{} = entry, ctx) do
    cond do
      String.ends_with?(entry.name, ".obj") ->
        case Schemas.load_object(entry.node_id, ctx.store) do
          {:ok, obj} -> {:ok, :object, obj}
          _ -> :not_found
        end

      String.ends_with?(entry.name, ".usr") ->
        load_player_for_lookup(entry, "", ctx)

      true ->
        :not_found
    end
  end

  @doc "Load the `Player` doc a `.usr` presence entry names, or a name-only stub."
  def load_player_for_lookup(entry, _needle, ctx) do
    bare = entry.name |> String.replace_suffix(".usr", "")
    path = "players/#{bare}"

    with {:ok, player_dir_uuid} <- World.resolve_path(path, ctx.root_uuid, ctx.store),
         {:ok, player} <- Schemas.load_player(player_dir_uuid, ctx.store) do
      {:ok, :player, player}
    else
      # CX-xe0r — the presence `.usr` is right here in the resolved scope, so a
      # player by this name IS present (the room render lists them). An
      # ephemeral / homeless session provisions no `players/<name>` home + Player
      # doc (player_session line ~902), so the home lookup fails — but `look`/
      # `examine` must NOT then lie "you don't see them here". Fall back to a
      # name-only render derived from the presence entry.
      _ -> {:ok, :player, %Player{name: bare, description: "A fellow traveler."}}
    end
  end

  # CX-cj3t.1.1: shared container resolver for `put`/`get ... from`/
  # `look in` — finds `phrase` in `dirs` (in order) and requires the
  # matched `.obj` to have `container?: true`; a non-container match
  # returns its name so callers can give a precise "not a container"
  # error rather than a generic not-found.
  @doc "Resolve `phrase` in `dirs` to a `.obj` entry, requiring `container?: true`."
  def resolve_container(phrase, dirs, ctx) do
    case find_entry_in_dirs(phrase, dirs, ctx.store) do
      {:ok, entry} ->
        case Schemas.load_object(entry.node_id, ctx.store) do
          {:ok, %Object{container?: true} = obj} -> {:ok, entry, obj}
          {:ok, %Object{name: name}} -> {:error, {:not_a_container, name}}
          _ -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end
end

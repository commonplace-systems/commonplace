defmodule Commonplace.Bots.NoteDoc do
  @moduledoc """
  Camillo C3c/C3d — a bot's private working docs as ZONED NOTE-METAS.

  A bot's scratchpad / memory / agenda are NOT objects (no verb surface) and NOT
  a new leaf-zone primitive (trust-core surgery) — they are ordinary zoned child
  dirs carrying a `__note.json` note-meta, minted through the SAME
  `Commonplace.MUD.ChildMutation.create_zoned_child/6` chokepoint every
  room/object goes through. Anchored UNDER the bot's HOME, the child INHERITS the
  home zone-stamp, so the bot's `{:subtree, home}[:write]` cert covers every write
  to it — which is exactly what makes these writes LAND under
  `local_write_gate: :enforce` (the previous MUD-root anchor was outside the
  bot's cert scope → `:capability_insufficient`).

  ## Why this shape (the two design pins)

    * **Zone-by-construction.** The caller NEVER supplies the zone;
      `create_zoned_child` derives it from the parent (`Trust.doc_zone(parent)`)
      and NODE-signs the stamp at genesis. Anchoring under the home makes the
      inherited zone == home, so the subtree cert authorizes the mint's
      entry-add AND every subsequent note write.

    * **Zone-preserving append (CX-cl65).** `append_text/4` grows the note via
      `World.merge_meta/5` — a SURGICAL raw-JSON field merge — NEVER a
      `%Struct{}` round-trip. A typed round-trip would DROP the node-signed
      `zone` stamp, and the subtree carve's stamp-protection rule then refuses
      the write (the doc becomes unwritable). `merge_meta` touches only the named
      field and leaves `zone` byte-identical.
  """

  alias Commonplace.MUD.{ChildMutation, World}
  alias Commonplace.Tree.Schema

  @note_filename "__note.json"

  @doc "The note-meta filename these working docs carry."
  def note_filename, do: @note_filename

  @doc """
  Get-or-create a zoned child dir named `name` under `parent_uuid`, carrying a
  `__note.json` note-meta seeded with `base_json` (a JSON string). The child
  INHERITS the parent's zone stamp via `ChildMutation.create_zoned_child/6`
  (node-signed), and the entry-add uses the bot's creds — so anchoring under a
  dir in the bot's home zone means the bot's `{:subtree, home}` cert authorizes
  it. Idempotent: an existing entry `name` is reused (get-before-create).

  Returns `{:ok, child_uuid}` or `{:error, reason}`.
  """
  @spec ensure_zoned_dir(String.t(), String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def ensure_zoned_dir(parent_uuid, name, base_json, ctx)
      when is_binary(parent_uuid) and is_binary(name) and is_binary(base_json) do
    case lookup_entry(parent_uuid, name, ctx.store) do
      {:ok, child_uuid} ->
        {:ok, child_uuid}

      :error ->
        ChildMutation.create_zoned_child(
          parent_uuid,
          name,
          @note_filename,
          base_json,
          ctx.store,
          bot_opts(ctx)
        )
    end
  end

  @doc """
  Append `value` to the string held in `field` of `note_dir_uuid`'s
  `__note.json` note-meta — SURGICAL and ZONE-PRESERVING.

  Reads the raw note-meta map (`World.get_meta_map/3`), concatenates `value` onto
  the existing string in `field` (or starts it), and writes back the SINGLE field
  via `World.merge_meta/5`. `merge_meta` never touches the `zone` stamp (it is a
  targeted field merge, not a typed round-trip — CX-cl65), so the node-signed
  stamp survives every append and the subtree carve keeps authorizing the write.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec append_text(String.t(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def append_text(note_dir_uuid, field, value, ctx)
      when is_binary(note_dir_uuid) and is_binary(field) and is_binary(value) do
    case World.get_meta_map(note_dir_uuid, @note_filename, ctx.store) do
      {:ok, map} ->
        existing =
          case Map.get(map, field) do
            s when is_binary(s) -> s
            _ -> ""
          end

        new_value = existing <> value

        case World.merge_meta(note_dir_uuid, @note_filename, %{field => new_value}, ctx.store, bot_opts(ctx)) do
          :ok -> :ok
          {:error, _} = err -> err
          other -> {:error, other}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Append `entry_map` (a map) to the LIST held in the `"entries"` field of
  `note_dir_uuid`'s `__note.json` note-meta — SURGICAL and ZONE-PRESERVING (the
  array/LOG shape, C3d).

  Reads the raw note-meta map (`World.get_meta_map/3`), appends `entry_map` onto
  the existing `entries` list (or starts one), and writes back the SINGLE
  `"entries"` field via `World.merge_meta/5`. As with `append_text/4`, the
  targeted field merge never touches the node-signed `zone` stamp (CX-cl65), so
  the subtree carve keeps authorizing the write on every append.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec append_entry(String.t(), map(), map()) :: :ok | {:error, term()}
  def append_entry(note_dir_uuid, entry_map, ctx)
      when is_binary(note_dir_uuid) and is_map(entry_map) do
    case World.get_meta_map(note_dir_uuid, @note_filename, ctx.store) do
      {:ok, map} ->
        existing =
          case Map.get(map, "entries") do
            list when is_list(list) -> list
            _ -> []
          end

        new_list = existing ++ [entry_map]

        case World.merge_meta(note_dir_uuid, @note_filename, %{"entries" => new_list}, ctx.store, bot_opts(ctx)) do
          :ok -> :ok
          {:error, _} = err -> err
          other -> {:error, other}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Read the `"entries"` LIST from `note_dir_uuid`'s `__note.json` note-meta.

  Returns the list, or `[]` when the note is missing / unreadable / carries no
  `entries` array. A pure read — needs only `ctx.store`.
  """
  @spec read_entries(String.t(), map()) :: [map()]
  def read_entries(note_dir_uuid, ctx) when is_binary(note_dir_uuid) do
    case fetch_entries(note_dir_uuid, ctx) do
      {:ok, list} ->
        list

      {:error, {:unreadable, reason}} ->
        raise "note doc #{note_dir_uuid} is UNREADABLE (#{inspect(reason)}). " <>
                "This is data CORRUPTION, not an empty note — see CX-r97r. " <>
                "Concurrent NoteDoc.append_entry/3 calls can splice the JSON " <>
                "into an unparseable hybrid. Returning [] here (the previous " <>
                "behaviour) made a corrupt transcript indistinguishable from a " <>
                "bot that never ran, which is how CX-t3bt cost weeks of " <>
                "misdiagnosis. Use fetch_entries/2 to handle this explicitly."
    end
  end

  @doc """
  Like `read_entries/2` but distinguishes ABSENT from CORRUPT.

  Returns `{:ok, list}` when the note is readable — including `{:ok, []}`
  for a note that legitimately has no entries yet, or no note at all.
  Returns `{:error, {:unreadable, reason}}` when the note EXISTS but its
  JSON does not parse.

  That distinction is the whole point (CX-r97r). `World.get_meta_map/3`
  ALREADY separates the two — a decode failure comes back as
  `{:error, %Jason.DecodeError{}}` while genuine absence is
  `:no_meta_entry` / `:no_doc` / `:empty_doc` — and the old
  `read_entries/2` discarded that with a bare `_ -> []`. A corrupt
  transcript therefore read as an empty one, nothing anywhere reported
  corruption, and a reader concluded the bot had never run while it was
  in fact working.
  """
  @spec fetch_entries(String.t(), map()) ::
          {:ok, [map()]} | {:error, {:unreadable, term()}}
  def fetch_entries(note_dir_uuid, ctx) when is_binary(note_dir_uuid) do
    case World.get_meta_map(note_dir_uuid, @note_filename, ctx.store) do
      {:ok, map} ->
        case Map.get(map, "entries") do
          list when is_list(list) -> {:ok, list}
          # Readable, but no entries array yet — a real empty.
          _ -> {:ok, []}
        end

      # Genuinely ABSENT: no note doc, no meta entry, or an empty doc.
      # An empty answer is the truth here.
      {:error, reason} when reason in [:no_meta_entry, :no_doc, :empty_doc] ->
        {:ok, []}

      # Anything else means the note EXISTS but could not be read — a
      # Jason.DecodeError on spliced JSON being the case that matters.
      {:error, reason} ->
        {:error, {:unreadable, reason}}
    end
  end

  # Bot-signed write opts (C1 / pin c): signing_context + cert_cids + signer_id,
  # all from the resolved ctx. Used both for the entry-add of a minted note dir
  # (create_zoned_child's entry_opts) and the merge_meta append.
  defp bot_opts(ctx) do
    [
      signing_context: ctx.signing_context,
      cert_cids: ctx.cert_cids,
      signer_id: ctx.signer_id
    ]
  end

  defp lookup_entry(parent_uuid, name, store) do
    with {:ok, schema} <- Commonplace.MUD.Schemas.load_dir_schema(parent_uuid, store),
         {:ok, %{node_id: node_id}} <- Schema.get_entry(schema, name) do
      {:ok, node_id}
    else
      _ -> :error
    end
  end
end

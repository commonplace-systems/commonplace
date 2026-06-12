defmodule Commonplace.MUD.World do
  @moduledoc """
  World handle for verb code. Verbs interact with the world *only*
  through this module so the public surface stays small and uniform.

  All ops are thin wrappers over CRDT edits + Phoenix PubSub.
  """

  alias Commonplace.Document.ContentType
  alias Commonplace.MUD.{Move, Schemas, Topics}
  alias Commonplace.Presence
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Schema, Walk}

  @doc "Resolve a path string to a UUID against the workspace root."
  def resolve_path(path, root_uuid, store \\ CommitStoreClient) when is_binary(path) do
    loader = fn uuid ->
      case DocBuilder.reconstruct_doc(store, uuid) do
        {:ok, doc} -> doc
        :none -> nil
      end
    end

    Walk.resolve_path(root_uuid, path, loader)
  end

  @doc "Send a private red event to a single player (the tell channel)."
  def tell(player_uuid, msg) when is_binary(player_uuid) do
    Topics.broadcast_player_tell(player_uuid, normalize_event(msg))
    :ok
  end

  @doc """
  Broadcast a red event to everyone subscribed to the room. Pass
  `:except` with a list of player UUIDs to skip — those listeners are
  expected to filter by the `except` field on the event payload.
  """
  def broadcast_room(room_uuid, msg, opts \\ []) when is_binary(room_uuid) do
    except = Keyword.get(opts, :except, [])
    payload = normalize_event(msg) |> Map.put(:except, except)
    Topics.broadcast_room(room_uuid, payload)
    :ok
  end

  @doc """
  Move a doc from one parent directory to another under green tokens
  (`Commonplace.MUD.Move` — the retired-`MoveServer` replacement).
  Returns `:ok` on success, `{:error, :gone}` if the doc no longer
  lives at the source path (race-loss), `{:error, :busy}` if the dir
  tokens stayed contended through the retry budget, or
  `{:error, :bursar_unavailable}` when no lock authority is reachable
  (fail-closed — never move unlocked).

  `name` is the entry name in both the source and destination schemas;
  for v0 we don't rename on move. `opts` are threaded to `Move.move/5`
  (notably `:store`).
  """
  def move(thing_uuid, name, source_dir_uuid, dest_dir_uuid, opts \\ [])
      when is_binary(thing_uuid) and is_binary(name) and is_binary(source_dir_uuid) and is_binary(dest_dir_uuid) do
    Move.move(thing_uuid, name, source_dir_uuid, dest_dir_uuid, opts)
  end

  @doc "Read a metadata struct out of a directory doc."
  def get_room(dir_uuid, store \\ CommitStoreClient), do: Schemas.load_room(dir_uuid, store)
  def get_object(dir_uuid, store \\ CommitStoreClient), do: Schemas.load_object(dir_uuid, store)
  def get_player(dir_uuid, store \\ CommitStoreClient), do: Schemas.load_player(dir_uuid, store)

  @doc "Set a top-level key on a metadata file, returning :ok or {:error, _}."
  def set_meta(dir_uuid, filename, key, value, store \\ CommitStoreClient) do
    with {:ok, schema} <- Schemas.load_dir_schema(dir_uuid, store),
         {:ok, entry} <- Schema.get_entry(schema, filename),
         {:ok, doc} <- DocBuilder.reconstruct_doc(store, entry.node_id),
         json when is_binary(json) <- ContentType.get_content(doc),
         {:ok, parsed} <- Jason.decode(json) do
      updated = Map.put(parsed, key, value) |> Jason.encode!()
      Schemas.write_meta_doc(entry.node_id, updated, store)
      :ok
    else
      :error -> {:error, :no_meta_entry}
      :none -> {:error, :no_doc}
      nil -> {:error, :empty_doc}
      other -> {:error, other}
    end
  end

  @doc """
  List entries in a directory (objects, players, sub-dirs). Returns
  `[%Schema.Entry{}]`.
  """
  def list_entries(dir_uuid, store \\ CommitStoreClient) do
    case Schemas.load_dir_schema(dir_uuid, store) do
      {:ok, schema} -> Schema.list_entries(schema)
      _ -> []
    end
  end

  @doc """
  Find an entry in a room directory matching `name` (case-insensitive
  substring on entry name OR on object aliases). Returns `{:ok, entry}`
  or `:error`.

  v0 scope: lookup is single-room. PlayerSession layers
  inventory→room→exits scoping on top.
  """
  def find_entry_by_name(dir_uuid, name, store \\ CommitStoreClient) when is_binary(name) do
    needle = String.downcase(name)
    entries = list_entries(dir_uuid, store)

    direct =
      Enum.find(entries, fn e ->
        base = e.name |> String.downcase() |> strip_extension()
        String.contains?(base, needle)
      end)

    case direct do
      %Schema.Entry{} = e ->
        {:ok, e}

      nil ->
        find_by_object_alias(entries, needle, store)
    end
  end

  defp find_by_object_alias(entries, needle, store) do
    obj_entries =
      Enum.filter(entries, fn e ->
        e.type == :dir and String.ends_with?(e.name, ".obj")
      end)

    Enum.find_value(obj_entries, :error, fn e ->
      case Schemas.load_object(e.node_id, store) do
        {:ok, %Schemas.Object{aliases: aliases}} ->
          if Enum.any?(aliases, fn a -> String.contains?(String.downcase(a), needle) end),
            do: {:ok, e},
            else: nil

        _ ->
          nil
      end
    end)
  end

  defp strip_extension(name) do
    case Path.extname(name) do
      "" -> name
      ext -> String.replace_suffix(name, ext, "")
    end
  end

  @doc "List all `.usr` presence file entries in a directory."
  def list_players_in(dir_uuid, store \\ CommitStoreClient) do
    list_entries(dir_uuid, store) |> Enum.filter(&String.ends_with?(&1.name, ".usr"))
  end

  @doc "List all `.obj` directory entries in a directory."
  def list_objects_in(dir_uuid, store \\ CommitStoreClient) do
    list_entries(dir_uuid, store)
    |> Enum.filter(fn e -> e.type == :dir and String.ends_with?(e.name, ".obj") end)
  end

  @doc "Read a presence doc map (name/type/status/heartbeat)."
  def read_presence(uuid, store \\ CommitStoreClient), do: Presence.read(uuid, store)

  defp normalize_event(text) when is_binary(text), do: %{kind: :custom, text: text}
  defp normalize_event(%{} = map), do: map
end

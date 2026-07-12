defmodule Commonplace.MUD.World do
  @moduledoc """
  World handle for verb code. Verbs interact with the world *only*
  through this module so the public surface stays small and uniform.

  All ops are thin wrappers over CRDT edits + Phoenix PubSub.
  """

  alias Commonplace.Document.ContentType
  alias Commonplace.MUD.{HolderMove, Move, Schemas, Take, Topics}
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

  @doc """
  Take `item_uuid` (entry `name`) from `room_uuid` into `inventory_uuid`
  for the player identified by `taker_identity`, under enforce — the
  push-not-pull elevated node transfer (see `Commonplace.MUD.Take`).
  """
  def take_item(item_uuid, name, room_uuid, inventory_uuid, taker_identity, opts \\ [])
      when is_binary(item_uuid) and is_binary(name) and is_binary(room_uuid) and
             is_binary(inventory_uuid) do
    Take.take(item_uuid, name, room_uuid, inventory_uuid, taker_identity, opts)
  end

  @doc """
  Drop `item_uuid` (entry `name`) from `inventory_uuid` into `room_uuid`
  for the player identified by `dropper_identity` — the invoker-holder
  push to the node (see `Commonplace.MUD.HolderMove`). After a successful
  drop the NODE holds the item's possession token, so it becomes
  takeable again (subject to the TAKE-zone-gate).
  """
  def drop_item(item_uuid, name, inventory_uuid, room_uuid, dropper_identity, opts \\ [])
      when is_binary(item_uuid) and is_binary(name) and is_binary(inventory_uuid) and
             is_binary(room_uuid) do
    node_identity =
      case Commonplace.Crypto.NodeIdentity.identity() do
        {:ok, id} -> id
        _ -> nil
      end

    HolderMove.push(item_uuid, name, inventory_uuid, room_uuid, dropper_identity, node_identity, opts)
  end

  @doc """
  CX-5c78 — deposit `item_uuid` (entry `name`) from `source_dir_uuid` into
  `container_uuid`, the PUT primitive. Structurally the `drop` push (invoker
  holder → node) but the destination is a CONTAINER dir instead of a room:
  the possession token moves `from_holder` → the NODE (`to_holder`), and the
  tree move elevates to node authority when the invoker can't write the
  (curated, node-owned) container directly under enforce — the SAME reviewed
  `HolderMove.push` machinery `drop`/`give` use, just a different dest dir.
  After a successful deposit the node holds the token, so the item becomes
  takeable-from-the-container (subject to the TAKE-zone-gate) — put/take
  symmetric.

  `from_holder` is the item's CURRENT possession holder: the invoker when the
  source is their own inventory, the node when the source is a room (a
  room-held item). Without a node identity (`to_holder`) the elevated path
  can't fire and a non-owner deposit fails closed — the correct enforce
  behavior. Locked/keyed containers are gated BEFORE this by `put_item_in`'s
  precheck (locking is the deposits-closed opt-out); a container cycle is
  refused via the threaded `:precheck`.
  """
  def deposit_item(item_uuid, name, source_dir_uuid, container_uuid, from_holder, opts \\ [])
      when is_binary(item_uuid) and is_binary(name) and is_binary(source_dir_uuid) and
             is_binary(container_uuid) do
    node_identity =
      case Commonplace.Crypto.NodeIdentity.identity() do
        {:ok, id} -> id
        _ -> nil
      end

    HolderMove.push(item_uuid, name, source_dir_uuid, container_uuid, from_holder, node_identity, opts)
  end

  @doc """
  Give `item_uuid` (entry `name`) from `inventory_uuid` to
  `recipient_inv_uuid`, transferring possession from `giver_identity` to
  `recipient_identity` — the invoker-holder push to the recipient (see
  `Commonplace.MUD.HolderMove`).
  """
  def give_item(item_uuid, name, inventory_uuid, recipient_inv_uuid, giver_identity, recipient_identity, opts \\ [])
      when is_binary(item_uuid) and is_binary(name) and is_binary(inventory_uuid) and
             is_binary(recipient_inv_uuid) do
    HolderMove.push(item_uuid, name, inventory_uuid, recipient_inv_uuid, giver_identity, recipient_identity, opts)
  end

  @doc "Read a metadata struct out of a directory doc."
  def get_room(dir_uuid, store \\ CommitStoreClient), do: Schemas.load_room(dir_uuid, store)
  def get_object(dir_uuid, store \\ CommitStoreClient), do: Schemas.load_object(dir_uuid, store)
  def get_player(dir_uuid, store \\ CommitStoreClient), do: Schemas.load_player(dir_uuid, store)

  @doc """
  CX-e12a — resolve the UUID of a dir's meta CHILD doc: `filename`'s
  `node_id` under the dir schema. This is the doc a meta write
  (`set_meta/6`) actually commits to — distinct from `dir_uuid`, the
  containing dir. The safe-verb elevation-authority (`Facade.write_guarded`)
  must judge node-ownership of THIS doc, not the host dir: a room dir's
  schema is churned by presence (player `.usr` entries added/removed on
  enter/leave, non-node-signed), so `node_owned?(room_dir)` is false and
  elevation was wrongly denied — even though the `__room.json` state child
  IS node-owned. Returns `{:ok, uuid}` or `{:error, :no_meta_entry}`.
  """
  def meta_doc_uuid(dir_uuid, filename, store \\ CommitStoreClient) do
    with {:ok, schema} <- Schemas.load_dir_schema(dir_uuid, store),
         {:ok, entry} <- Schema.get_entry(schema, filename) do
      {:ok, entry.node_id}
    else
      :error -> {:error, :no_meta_entry}
      {:error, _} = err -> err
    end
  end

  @doc """
  Set a top-level key on a metadata file, returning :ok or {:error, _}.

  CX-93ea: the underlying `Schemas.write_meta_doc/4` call is checked —
  a rejected commit (e.g. `{:trust_rejected, _}` under
  `local_write_gate: :enforce`) now returns `{:error, _}` here instead
  of a false `:ok`.

  `opts` (CX-lg06): `:signing_context`, `:cert_cids`, `:signer_id` —
  threaded into the underlying `Schemas.write_meta_doc/4`; see
  `Commonplace.MUD.SignedWrite`.
  """
  def set_meta(dir_uuid, filename, key, value, store \\ CommitStoreClient, opts \\ []) do
    merge_meta(dir_uuid, filename, %{key => value}, store, opts)
  end

  @doc """
  Surgically merge `updates` (a map of top-level key => value) into a meta
  file's RAW JSON, preserving EVERY key the typed structs would silently drop
  on a re-encode — most importantly the node-signed `zone` stamp
  (`Commonplace.MUD.ChildMutation`), but also the freeform verb `state` submap
  (CX-hqk5) and any field added later. A `nil` value DELETES its key (resetting
  it to the encoder's omit-when-default form, e.g. going `:public`).

  CX-cl65: this is the ONLY correct shape for a verb that MUTATES an existing
  zoned doc. A `%Room{}`/`%Object{}` struct round-trip (`get_room` →
  `%{room | ...}` → `encode_room`) drops `zone` (the struct has no such field),
  and the subtree write-carve reads the resulting `zone: home → absent` as a
  protected-field-immutability violation and DENIES the write — even for the
  doc's rightful owner. Never round-trip a zoned doc through the typed struct on
  the write path; merge the raw map instead.

  `opts` (CX-lg06): `:signing_context`, `:cert_cids`, `:signer_id` — threaded
  into `Schemas.write_meta_doc/4`; see `Commonplace.MUD.SignedWrite`.
  """
  def merge_meta(dir_uuid, filename, updates, store \\ CommitStoreClient, opts \\ [])
      when is_map(updates) do
    with {:ok, schema} <- Schemas.load_dir_schema(dir_uuid, store),
         {:ok, entry} <- Schema.get_entry(schema, filename),
         {:ok, doc} <- DocBuilder.reconstruct_doc(store, entry.node_id),
         json when is_binary(json) <- ContentType.get_content(doc),
         {:ok, parsed} when is_map(parsed) <- Jason.decode(json) do
      {deletes, sets} = Enum.split_with(updates, fn {_k, v} -> is_nil(v) end)

      updated_map =
        parsed
        |> Map.merge(Map.new(sets))
        |> Map.drop(Enum.map(deletes, fn {k, _} -> k end))

      # CX-e8xj STATE FIREWALL: a token-elevated (possession→state) write MUST
      # touch ONLY the `"state"` submap — every other key (the node-signed `zone`
      # stamp + all typed/protected fields) byte-identical before/after. This is
      # the load-bearing guard that makes possession-elevation safe to OVERRIDE
      # the CX-orlm AXIS-2 zone veto: a holder can drive an object's runtime state
      # but can NEVER re-stamp/re-home it to escape that veto. Fail-closed,
      # pre-commit. Only the holder-state path sets `:state_only` (see
      # `Facade.holder_state_write`); it is stripped before the signing opts flow
      # on. A no-op change trivially passes (everything-except-state equal).
      if Keyword.get(opts, :state_only, false) and
           Map.delete(parsed, "state") != Map.delete(updated_map, "state") do
        {:error, :state_firewall}
      else
        Schemas.write_meta_doc(
          entry.node_id,
          Jason.encode!(updated_map),
          store,
          Keyword.delete(opts, :state_only)
        )
      end
    else
      :error -> {:error, :no_meta_entry}
      :none -> {:error, :no_doc}
      nil -> {:error, :empty_doc}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  end

  @doc """
  Read a dir's meta doc (`filename`) as its RAW decoded JSON map —
  including keys the typed structs drop (e.g. the `"state"` submap
  freeform verb state lives in, CX-hqk5). Returns `{:ok, map}`,
  `{:error, :no_meta_entry}`, `{:error, :no_doc}`, or a decode error.
  """
  def get_meta_map(dir_uuid, filename, store \\ CommitStoreClient) do
    with {:ok, schema} <- Schemas.load_dir_schema(dir_uuid, store),
         {:ok, entry} <- Schema.get_entry(schema, filename),
         {:ok, doc} <- DocBuilder.reconstruct_doc(store, entry.node_id),
         json when is_binary(json) <- ContentType.get_content(doc),
         {:ok, parsed} when is_map(parsed) <- Jason.decode(json) do
      {:ok, parsed}
    else
      :error -> {:error, :no_meta_entry}
      :none -> {:error, :no_doc}
      nil -> {:error, :empty_doc}
      {:error, _} = err -> err
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
  substring on entry name, the object's CURRENT display name, OR its
  aliases). Returns `{:ok, entry}` or `:error`.

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
        find_by_object_name(entries, needle, store)
    end
  end

  # CX-o2hw: match the object's CURRENT display name (the meta `name`) as well as
  # its aliases — NOT just the schema entry-key. The instance key is frozen at
  # `<creation-name>-<uuid>.obj`, so after `@name widget gizmo` the key still
  # reads "widget" and only the meta `name` becomes "gizmo"; without matching the
  # live display name, a renamed object was unaddressable by the ONLY name a
  # player can see. Reading the name fresh from meta means `@name` needs no
  # tree-key rewrite to take effect.
  defp find_by_object_name(entries, needle, store) do
    obj_entries =
      Enum.filter(entries, fn e ->
        e.type == :dir and String.ends_with?(e.name, ".obj")
      end)

    Enum.find_value(obj_entries, :error, fn e ->
      case Schemas.load_object(e.node_id, store) do
        {:ok, %Schemas.Object{name: name, aliases: aliases}} ->
          if Enum.any?([name | aliases], fn a ->
               is_binary(a) and String.contains?(String.downcase(a), needle)
             end),
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

  @doc """
  CX-i9j3 (UI Inc-2): materialize the SELF-VIEW room-pane sections for the
  committed view-doc — a re-projection of the SAME room-state the `look`
  display already computes (name/desc/exits/contents/occupants), shaped for
  `Commonplace.MUD.SessionView.replace_room/2`.

  `self_filename` is the observer's own `.usr` presence filename, excluded
  from occupants (you don't list yourself). Returns
  `{:ok, %{name, desc, exits: [{dir, to_label}], contents: [name],
  occupants: [name]}}`, or `{:error, reason}` when the room can't be
  loaded. This is self-view of already-visible state — no new disclosure.

  Exits carry only the DIRECTION, never the destination room's name: the
  live `look` shows directions only, and labelling an exit with the
  adjacent room's name would read that neighbour's meta and disclose a
  room the observer hasn't traversed — the adjacent-room-visibility
  question deferred to read-scoping (#13). Keeping exits direction-only
  preserves Inc-2's zero-new-disclosure invariant (plan #6868).

  ## Read-scoping P2 gate (CX-ivqz, Seam 1/2.1)

  ALWAYS consults `Commonplace.Trust.Read.authorized?/3` with the room's
  OWN carried, node-signed `visibility`/`owner` fields — `:public` (or
  absent, every pre-P2 room) short-circuits inside the verifier, so this
  is a zero-behavior-change no-op for the overwhelming majority of rooms
  (no-regression). A `capability_gated` room refused to `opts[:viewer]`
  returns `{:error, :read_denied}` — NEVER partial data (attack Z2: a
  refused room must not leak name/desc/exits/contents/occupants).
  Judged ONLY from the room's carried fields, never live
  occupancy/presence (attack Z7 — a security gate must not consult
  mutable world state).
  """
  @spec room_snapshot(String.t(), String.t(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def room_snapshot(room_uuid, self_filename, store \\ CommitStoreClient, opts \\ []) do
    viewer = Keyword.get(opts, :viewer)

    case get_room(room_uuid, store) do
      {:ok, %Schemas.Room{} = room} ->
        case Commonplace.Trust.Read.authorized?(viewer, room_uuid,
               visibility: room.visibility,
               owner: room.owner,
               store: store
             ) do
          :ok ->
            {:ok,
             %{
               name: room.name,
               desc: room.description,
               exits: snapshot_exits(room.exits),
               contents: snapshot_contents(room_uuid, store),
               occupants: snapshot_occupants(room_uuid, self_filename, store)
             }}

          {:error, _} = denied ->
            denied
        end

      {:error, _} = err ->
        err
    end
  end

  # Direction-only exits (sorted). `to` is left empty — NO adjacent-room
  # meta read — so the pane never discloses a neighbouring room's name to
  # an observer who hasn't traversed there (plan #6868; the `<exit dir to>`
  # schema still carries a `to` slot for a future read-scoped version).
  defp snapshot_exits(exits) do
    exits
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn dir -> {dir, ""} end)
  end

  defp snapshot_contents(room_uuid, store) do
    list_objects_in(room_uuid, store)
    |> Enum.map(fn e ->
      case Schemas.load_object(e.node_id, store) do
        {:ok, %Schemas.Object{name: name}} -> name
        _ -> String.replace_suffix(e.name, ".obj", "")
      end
    end)
  end

  defp snapshot_occupants(room_uuid, self_filename, store) do
    list_players_in(room_uuid, store)
    |> Enum.reject(fn e -> e.name == self_filename end)
    |> Enum.map(fn e -> String.replace_suffix(e.name, ".usr", "") end)
  end

  @doc "Read a presence doc map (name/type/status/heartbeat)."
  def read_presence(uuid, store \\ CommitStoreClient), do: Presence.read(uuid, store)

  @doc """
  Locate the room a `.usr` presence file currently lives in by walking
  the tree from `root_uuid`. Presence does NOT relocate with
  `current_room_uuid` bookkeeping — it physically moves in the schema
  tree — so this is the authoritative locator. Returns
  `{:ok, room_uuid, presence_uuid}` or `:not_found`. Cycle-safe via a
  visited set.
  """
  def find_presence(root_uuid, presence_filename, store \\ CommitStoreClient)
      when is_binary(root_uuid) and is_binary(presence_filename) do
    walk_for_presence(root_uuid, presence_filename, store, MapSet.new())
  end

  @doc """
  Like `find_presence/3` but returns only `{:ok, room_uuid}` (drops the
  presence UUID). Used by verb dispatch to reconcile a session's room
  after a `move_self` (CX-oh5k).
  """
  def find_presence_room(root_uuid, presence_filename, store \\ CommitStoreClient) do
    case find_presence(root_uuid, presence_filename, store) do
      {:ok, room_uuid, _presence_uuid} -> {:ok, room_uuid}
      :not_found -> :not_found
    end
  end

  defp walk_for_presence(uuid, filename, store, seen) do
    if MapSet.member?(seen, uuid) do
      :not_found
    else
      seen = MapSet.put(seen, uuid)

      case Schemas.load_dir_schema(uuid, store) do
        {:ok, schema} ->
          entries = Schema.list_entries(schema)

          case Enum.find(entries, fn e -> e.name == filename end) do
            %Schema.Entry{node_id: presence_uuid} ->
              {:ok, uuid, presence_uuid}

            nil ->
              entries
              |> Enum.filter(&(&1.type == :dir))
              |> Enum.find_value(:not_found, fn entry ->
                case walk_for_presence(entry.node_id, filename, store, seen) do
                  :not_found -> nil
                  result -> result
                end
              end)
          end

        _ ->
          :not_found
      end
    end
  end

  defp normalize_event(text) when is_binary(text), do: %{kind: :custom, text: text}
  defp normalize_event(%{} = map), do: map
end

defmodule Commonplace.MUD.World do
  @moduledoc """
  World handle for verb code. Verbs interact with the world *only*
  through this module so the public surface stays small and uniform.

  All ops are thin wrappers over CRDT edits + Phoenix PubSub.
  """

  require Logger

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
      when is_binary(thing_uuid) and is_binary(name) and is_binary(source_dir_uuid) and
             is_binary(dest_dir_uuid) do
    Move.move(thing_uuid, name, source_dir_uuid, dest_dir_uuid, opts)
  end

  @doc """
  CX-avzp — THE guarded presence-move chokepoint. Relocate a player's OWN
  `.usr` presence into `dest_dir_uuid`, but ONLY after the destination's
  read-visibility admits `opts[:viewer]`. Every path that moves a presence
  — `do_go`, `do_teleport`, and the citizen-verb `Facade.move_self` —
  MUST route through here so the gate is closed-by-construction against a
  future 4th mover (a bare `move/5` is generic and shared with OBJECT moves
  via `Facade.move_object`, so it is NOT gated directly).

  ## Why gate a MOVE on a READ (nav ⟂ access-control coherence)

  Placing presence in a room SUBSCRIBES the session to that room's live
  event stream (`PlayerSession.handle_verb_result({:moved})` →
  `Topics.subscribe_room`) and lists the player in its occupancy. A
  private room's event-stream + occupancy IS read-scoped content, so
  entering = subscribing = a READ. Gating the move on
  `Trust.Read.authorized?` is therefore read-scoping the presence/event
  channel — NOT a spatial-reachability security boundary (which plan
  #6069 correctly forbids). Public rooms short-circuit `:ok` inside the
  verifier, so this is a zero-behavior-change no-op for the overwhelming
  majority of moves (no-regression).

  Deny is ATOMIC: on `{:error, :read_denied}` NO presence write happens,
  so no depart/arrive broadcast fires and — because the subscribe is
  structurally downstream of the `{:moved}` result the callers only emit
  on `:ok` — the denied player is NEVER subscribed (the eavesdrop leak is
  closed by construction, not by suppressing the render after the fact).

  Judged ONLY from the dest room's OWN carried, node-signed
  `visibility`/`owner` fields (mirrors `room_snapshot/4` exactly), never
  live occupancy/presence.

  ## Fail-direction (CX-orlm absence-vs-transient — plan-ruled)

  The read can fail two structurally different ways, and they fail in
  OPPOSITE directions:

    * TRUE STRUCTURAL ABSENCE — the dir carries no `__room.json` entry at
      all (`{:no_meta_entry, _}`), or the dest dir itself does not resolve.
      By the P2 default-public model a dir with no visibility field is not
      a gated room, and an absent dest makes the underlying `move` fail
      cleanly on its own (no presence lands, no leak). Fail OPEN — this is
      the no-regression case for meta-less/legacy exit targets.

    * PRESENT-BUT-UNREADABLE — the `__room.json` entry EXISTS but its doc
      could not be resolved or decoded (a `:capability_gated` room whose
      meta-child commits have not replicated yet under catch-up sync, or a
      corrupt body). The entry proves intent-to-carry-room-meta, so we
      MUST NOT assume public in the read-error window. Fail CLOSED (deny)
      — a known-private room must never leak just because its visibility
      momentarily could not be read.

  Distinguished by re-checking the dir schema: if the DIR resolves but the
  meta child does not, the private-meta child is the unreadable part → deny;
  if the dir itself is absent, let the move proceed and fail cleanly.
  """
  def move_presence(player_uuid, presence_filename, source_dir_uuid, dest_dir_uuid, opts \\ [])
      when is_binary(player_uuid) and is_binary(presence_filename) and
             is_binary(source_dir_uuid) and is_binary(dest_dir_uuid) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    viewer = Keyword.get(opts, :viewer)
    move_opts = Keyword.delete(opts, :viewer)

    case presence_read_gate(viewer, dest_dir_uuid, store) do
      :ok -> move(player_uuid, presence_filename, source_dir_uuid, dest_dir_uuid, move_opts)
      {:error, _} = denied -> denied
    end
  end

  defp presence_read_gate(viewer, dest_dir_uuid, store) do
    case get_room(dest_dir_uuid, store) do
      {:ok, %Schemas.Room{} = room} ->
        Commonplace.Trust.Read.authorized?(viewer, dest_dir_uuid,
          visibility: room.visibility,
          owner: room.owner,
          store: store
        )

      # STRUCTURAL ABSENCE — dir present, no __room.json entry: not a gated
      # room (P2 default-public). Fail OPEN (no-regression for meta-less exits).
      {:error, {:no_meta_entry, _}} ->
        :ok

      # PRESENT-BUT-UNREADABLE vs DIR-ABSENT — see moduledoc fail-direction.
      # Re-check the dir: dir resolves ⇒ the __room.json meta child is the
      # unreadable part ⇒ can't read a known-private room's visibility ⇒ fail
      # CLOSED. Dir itself absent ⇒ the move fails cleanly on its own ⇒ let it
      # through (fail open) so callers keep their real "can't go there" error.
      {:error, _} ->
        case Schemas.load_dir_schema(dest_dir_uuid, store) do
          {:ok, _} -> {:error, :read_denied}
          _ -> :ok
        end
    end
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

    HolderMove.push(
      item_uuid,
      name,
      inventory_uuid,
      room_uuid,
      dropper_identity,
      node_identity,
      opts
    )
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
    store = Keyword.get(opts, :store, CommitStoreClient)

    # CX-2cmq — SYMMETRIC with extraction: a non-owner deposit may node-elevate
    # ONLY into a node-owned/curated container (the same reachability gate
    # `Take` applies to extraction). `HolderMove.push` would otherwise node-sign
    # the container-add UNCONDITIONALLY, so a visitor over-elevated a write into
    # ANY container incl. a citizen's private home — deposit landed but
    # extraction correctly refused → the item was stranded (the roach-motel).
    # Gate here so both sides gate identically: curated → both open, citizen →
    # both closed (an honest "you can't put that there" instead of eating items).
    if Take.deposit_elevation_allowed?(container_uuid, source_dir_uuid, opts, store) do
      node_identity =
        case Commonplace.Crypto.NodeIdentity.identity() do
          {:ok, id} -> id
          _ -> nil
        end

      HolderMove.push(
        item_uuid,
        name,
        source_dir_uuid,
        container_uuid,
        from_holder,
        node_identity,
        opts
      )
    else
      {:error, {:trust_rejected, :not_node_owned_container}}
    end
  end

  @doc """
  Give `item_uuid` (entry `name`) from `inventory_uuid` to
  `recipient_inv_uuid`, transferring possession from `giver_identity` to
  `recipient_identity` — the invoker-holder push to the recipient (see
  `Commonplace.MUD.HolderMove`).
  """
  def give_item(
        item_uuid,
        name,
        inventory_uuid,
        recipient_inv_uuid,
        giver_identity,
        recipient_identity,
        opts \\ []
      )
      when is_binary(item_uuid) and is_binary(name) and is_binary(inventory_uuid) and
             is_binary(recipient_inv_uuid) do
    HolderMove.push(
      item_uuid,
      name,
      inventory_uuid,
      recipient_inv_uuid,
      giver_identity,
      recipient_identity,
      opts
    )
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

  # CX-r97r: bounded retry count for merge_meta's read-modify-write CAS
  # loop (see merge_meta/5 doc). Each attempt re-captures the version,
  # re-reads, re-merges, and re-diffs from scratch — never replays stale
  # diff bytes.
  @merge_meta_max_attempts 5

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

  CX-r97r: this is a read-modify-write over `Schemas.write_meta_doc/4`, which
  computes a MINIMAL POSITIONAL TEXT DIFF from the doc content read here to
  the merged JSON. `CommitStoreClient`'s default write path retries a lost
  CAS by REPLAYING THE SAME diff bytes onto whatever parent is current —
  correct for ordinary CRDT updates, but a positional diff computed against
  now-stale text splices into a concurrent writer's text and produces
  unparseable, corrupted JSON. So this function instead captures the doc's
  version (`Schemas.latest_commit_id/2`) BEFORE reading, passes it through as
  `:expect_parent` (opt-in strict CAS, no retry inside `CommitStoreClient`),
  and on `{:error, :parent_moved}` re-runs the WHOLE read→merge→write
  sequence from scratch against a freshly-observed version, bounded by
  `@merge_meta_max_attempts`. KNOWN GAP: this CAS is local-write-path only —
  see `CommitStoreClient.create_chained_commit/5`'s remote branch, which
  ignores `:expect_parent` and has no compare-and-swap on that path.
  """
  def merge_meta(dir_uuid, filename, updates, store \\ CommitStoreClient, opts \\ [])
      when is_map(updates) do
    update_meta(dir_uuid, filename, fn _current -> updates end, store, opts)
  end

  @doc """
  Read-modify-write primitive over a meta file: like `merge_meta/5`, but
  `fun` is a 1-arity function (current decoded meta map => updates map,
  same top-level key => value / nil-deletes-key semantics as `merge_meta/5`)
  instead of a static map.

  CX-r97r: `fun` is invoked INSIDE the CAS retry loop, on every attempt,
  against THAT attempt's freshly-read current map. This is the correct
  primitive for a read-modify-write (append-to-list, increment,
  merge-into-nested) where the new value depends on the old one —
  `merge_meta/5` with a pre-computed whole value is only safe when the new
  value does NOT depend on the old one, because a lost-CAS retry there
  replays the same frozen `updates` map against the freshly-read state
  rather than recomputing it, silently clobbering a concurrent writer's
  change.
  """
  def update_meta(dir_uuid, filename, fun, store \\ CommitStoreClient, opts \\ [])
      when is_function(fun, 1) do
    with {:ok, schema} <- Schemas.load_dir_schema(dir_uuid, store),
         {:ok, entry} <- Schema.get_entry(schema, filename) do
      merge_meta_cas(entry.node_id, fun, store, opts, @merge_meta_max_attempts)
    else
      :error -> {:error, :no_meta_entry}
      {:error, _} = err -> err
    end
  end

  defp merge_meta_cas(_node_id, _fun, _store, _opts, 0), do: {:error, :write_conflict}

  defp merge_meta_cas(node_id, fun, store, opts, attempts_left) do
    expected = Schemas.latest_commit_id(node_id, store)

    with {:ok, doc} <- DocBuilder.reconstruct_doc(store, node_id),
         json when is_binary(json) <- ContentType.get_content(doc),
         {:ok, parsed} when is_map(parsed) <- Jason.decode(json) do
      updates = fun.(parsed)

      if updates == %{} do
        # An empty updates map means the caller's modify step decided there is
        # nothing to change (e.g. `NoteDoc.append_entry_unless/4`'s dedupe
        # predicate matched) -- a true no-op: no write, no commit, no CAS
        # attempt spent.
        :ok
      else
        {deletes, sets} = Enum.split_with(updates, fn {_k, v} -> is_nil(v) end)

        updated_map =
          parsed
          |> Map.merge(Map.new(sets))
          |> Map.drop(Enum.map(deletes, fn {k, _} -> k end))

        # CX-e8xj STATE FIREWALL: a token-elevated (possession->state) write MUST
        # touch ONLY the `"state"` submap -- every other key (the node-signed `zone`
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
          write_opts =
            opts
            |> Keyword.delete(:state_only)
            |> Keyword.put(:expect_parent, expected)

          case Schemas.write_meta_doc(node_id, Jason.encode!(updated_map), store, write_opts) do
            {:error, :parent_moved} ->
              merge_meta_cas(node_id, fun, store, opts, attempts_left - 1)

            other ->
              other
          end
        end
      end
    else
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

  @doc """
  CX-c6ph — best match for `name` in `dir_uuid` WITH a quality score, so callers
  resolving across multiple dirs can prefer an EXACT-name match in one dir over an
  ALIAS/partial match in another. Returns `{score, entry}` (higher = better) or nil.
  Scoring: exact entry-key base OR exact object display-name = 4; exact alias = 3;
  partial (substring) name = 2; partial alias = 1. Mirrors `find_entry_by_name/3`'s
  matching surface (entry-key base via strip_extension, plus object meta name+aliases).
  """
  def find_entry_ranked(dir_uuid, name, store \\ CommitStoreClient) when is_binary(name) do
    needle = String.downcase(name)

    list_entries(dir_uuid, store)
    |> Enum.map(fn e -> {entry_match_score(e, needle, store), e} end)
    |> Enum.filter(fn {s, _} -> s > 0 end)
    |> Enum.max_by(fn {s, _} -> s end, fn -> nil end)
  end

  defp entry_match_score(e, needle, store) do
    base = e.name |> String.downcase() |> strip_extension()

    name_score =
      cond do
        base == needle -> 4
        word_prefix_match?(base, needle) -> 2
        true -> 0
      end

    obj_score =
      if e.type == :dir and String.ends_with?(e.name, ".obj") do
        case Schemas.load_object(e.node_id, store) do
          {:ok, %Schemas.Object{name: dname, aliases: aliases}} ->
            dn = String.downcase(dname || "")
            aliases = Enum.filter(aliases, &is_binary/1) |> Enum.map(&String.downcase/1)

            cond do
              dn == needle -> 4
              Enum.any?(aliases, &(&1 == needle)) -> 3
              dn != "" and word_prefix_match?(dn, needle) -> 2
              Enum.any?(aliases, &word_prefix_match?(&1, needle)) -> 1
              true -> 0
            end

          _ ->
            0
        end
      else
        0
      end

    max(name_score, obj_score)
  end

  # CX-ypgf — a partial (non-exact) noun match must anchor at a WORD boundary:
  # the needle matches iff `haystack`, or one of its whitespace-separated words,
  # STARTS WITH it. Prevents a short token / preposition matching mid-word
  # ('on' → 'ir**on** ingot', so 'step on warppad' wrongly resolved the carried
  # iron ingot). Prefix (not just whole-word) matching keeps the MUD convention
  # that you can type the start of a noun ('ingot' → 'iron ingot', 'warp' →
  # 'warppad').
  defp word_prefix_match?(haystack, needle) do
    String.starts_with?(haystack, needle) or
      haystack |> String.split() |> Enum.any?(&String.starts_with?(&1, needle))
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
  @spec room_snapshot(String.t(), String.t(), term(), keyword()) ::
          {:ok, map()} | {:error, term()}
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
  `{:ok, room_uuid, presence_uuid}`, `:not_found`, or — CX-iwf5, cp-plan
  ruling #8965 — `{:error, :ambiguous_presence}` when the SAME filename
  is found in MORE THAN ONE room (a fork). The walk does NOT short-circuit
  on the first hit; it visits the WHOLE tree (cycle-safe via a visited
  set) so a duplicate is actually detected rather than silently arbitrated
  by tree-walk order.

  REFUSE-AND-DEGRADE, never silently pick one: a caller that only handles
  `{:ok, _, _}` / `:not_found` and adds a catch-all for anything else gets
  the SAME graceful "not found" posture for an ambiguous match as for a
  genuinely absent one — never acts on a coin-flip-chosen room. Every
  caller in this codebase (`Commonplace.Bots.MudContext.resolve/4`,
  `Commonplace.MUD.PlayerSession`, `Commonplace.Bots.Worker.Loop`'s
  CX-mpk0 position refresh, `Commonplace.Bots.Dispatcher`'s presence
  keep-alive beat) was updated to degrade this way rather than crash on
  an unmatched `case` clause.
  """
  def find_presence(root_uuid, presence_filename, store \\ CommitStoreClient)
      when is_binary(root_uuid) and is_binary(presence_filename) do
    case walk_for_presence_all(root_uuid, presence_filename, store, MapSet.new()) do
      [] ->
        :not_found

      [{room_uuid, presence_uuid}] ->
        {:ok, room_uuid, presence_uuid}

      matches when is_list(matches) ->
        Logger.warning(
          "World.find_presence: AMBIGUOUS presence #{presence_filename} found in " <>
            "#{length(matches)} rooms (#{inspect(Enum.map(matches, &elem(&1, 0)))}) — refusing to pick one"
        )

        {:error, :ambiguous_presence}
    end
  end

  @doc """
  Like `find_presence/3` but returns only `{:ok, room_uuid}` (drops the
  presence UUID). Used by verb dispatch to reconcile a session's room
  after a `move_self` (CX-oh5k). An ambiguous match (CX-iwf5) collapses
  to `:not_found` here too — this function's callers already only branch
  on `{:ok, _}` / `:not_found`, and "can't tell which room" is honestly
  the same as "don't know the room" from this call's point of view.
  """
  def find_presence_room(root_uuid, presence_filename, store \\ CommitStoreClient) do
    case find_presence(root_uuid, presence_filename, store) do
      {:ok, room_uuid, _presence_uuid} -> {:ok, room_uuid}
      :not_found -> :not_found
      {:error, :ambiguous_presence} -> :not_found
    end
  end

  # Walks the WHOLE tree (never short-circuits on the first hit) and
  # returns every `{room_uuid, presence_uuid}` match for `filename` —
  # `find_presence/3` above decides absent/single/ambiguous from the
  # length of this list.
  defp walk_for_presence_all(uuid, filename, store, seen) do
    if MapSet.member?(seen, uuid) do
      []
    else
      seen = MapSet.put(seen, uuid)

      case Schemas.load_dir_schema(uuid, store) do
        {:ok, schema} ->
          entries = Schema.list_entries(schema)

          here =
            case Enum.find(entries, fn e -> e.name == filename end) do
              %Schema.Entry{node_id: presence_uuid} -> [{uuid, presence_uuid}]
              nil -> []
            end

          nested =
            entries
            |> Enum.filter(&(&1.type == :dir))
            |> Enum.flat_map(&walk_for_presence_all(&1.node_id, filename, store, seen))

          here ++ nested

        _ ->
          []
      end
    end
  end

  defp normalize_event(text) when is_binary(text), do: %{kind: :custom, text: text}
  defp normalize_event(%{} = map), do: map
end

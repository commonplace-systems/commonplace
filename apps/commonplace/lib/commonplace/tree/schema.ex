defmodule Commonplace.Tree.Schema do
  @moduledoc """
  Directory-as-CRDT — the substrate atom for Commonplace's tree.

  A schema doc *is* a directory. It maps child names to the UUIDs
  of other docs (files or sub-directories), with metadata about
  whether each child should sync. Walk a path through Commonplace's
  tree and you're walking a chain of schema docs, one per directory.

      Yelixer.Doc
        ├── "schema"  (YMap)  — meta-state for this directory
        │     └── "version" → "1"
        └── "entries" (YMap)  — child name → encoded entry
              ├── "alice.usr"      → "doc:f8ff…"
              ├── "drafts"         → "dir:6fd7…"
              └── "deactivated"    → "dir:bdc6…:nosync"

  Every other tree module — `Commonplace.Tree.Walk`,
  `Commonplace.Tree.Lookup`, `Commonplace.Tree.DocBuilder`,
  `Commonplace.Tree.Fork`, `Commonplace.Tree.Merge` — operates over
  schema docs. Every doc tree in the workspace bottoms out in
  schemas; everything else (text, JSON metadata, presence files,
  binaries) is a *leaf* referenced by UUID from inside a schema's
  `entries`.

  ## Why two top-level YMaps

  `"schema"` carries meta-state that belongs to the directory itself
  — currently just `"version"`, eventually room for `root` config
  and future evolution. `"entries"` carries the directory's actual
  contents. Splitting them lets the meta-state grow without
  colliding with user-chosen entry names. (A future `"version"` key
  in `entries` would mean a directory whose child file is named
  "version"; meta lives in its own YMap to avoid that.)

  ## The encoded entry value: `"type:uuid[:nosync]"`

  Each `entries[name]` is a string. The format is:

      "doc:<uuid>"                — a file entry, sync enabled
      "dir:<uuid>"                — a directory entry, sync enabled
      "doc:<uuid>:nosync"         — file entry, sync disabled
      "dir:<uuid>:nosync"         — directory entry, sync disabled

  Why a string instead of a structured value (a nested YMap, say)?
  Three reasons:

    1. **Yelixer YMap values are scalars.** A nested YMap could be
       expressed as a sub-type with the `__sub:CLIENT:CLOCK` naming
       scheme from `Yelixer.Doc` — but that costs a separate type
       registration and an additional doc-shape entry per directory
       child. At Commonplace's scale (thousands of directories with
       thousands of entries) the overhead is real.
    2. **YMap LWW per key gives clean concurrent semantics for
       free.** Two replicas concurrently calling `add_file` for the
       same name resolve via Yjs's `(Lamport, clientID)` tiebreak,
       same as any other YMap key. A structured value would need
       independent LWW on each sub-field, which is *not* what the
       directory-entry contract wants ("the entry is one logical
       value, not a record of independently editable fields").
    3. **The `:` delimiter is safe.** UUIDs are hex digits and
       dashes (no colons); our type tags are `"doc"` and `"dir"`
       (no colons); the optional `"nosync"` suffix is a fixed token.
       `String.split/2` round-trips cleanly with no escaping logic.

  `encode_entry/3` and `decode_entry/1` are the codec; everything
  in this module reads and writes through them.

  ## Honorific extensions and the presence-uniqueness invariant (CX-edy)

  Four file extensions are reserved as **honorifics** for presence
  documents:

      .bot   .exe   .usr   .who

  These extensions are how `Commonplace.Presence` advertises the
  live existence of an actor. The single-presence-location
  invariant ("an actor's `.usr` lives at exactly one path") is what
  lets cross-cluster presence queries terminate; if it ever
  weakened, an attacker (or a buggy CLI) could double-publish a
  presence file under the same name in two locations and corrupt
  every query that relies on the invariant.

  `forbid_honorific!/1` is the **opt-in guard** that untrusted
  write entrypoints (CLI `ln`, CLI `import`, future MCP tools) must
  call before adding user-provided names. Trusted internal callers
  — `Commonplace.Presence.create/3`, `Presence.move/3` — bypass the
  guard because they're the canonical path for honorific files.
  The check is case-insensitive (`Foo.USR` and `bar.Usr` are both
  rejected) so the comparison can't be circumvented by case
  shenanigans.

  Living the guard *here* matters: this module is the chokepoint
  for every directory mutation. Anywhere else, an attacker could
  add a `.usr` entry by going around the guard.

  ## The sync flag and branch deactivation

  The `:nosync` suffix is a per-entry "skip me when computing sync
  subscriptions" flag. The path-prefix subscription model — the
  sync agent subscribes to whatever entries the workspace's local
  config wants to mirror — uses the flag to keep deactivated
  branches off the wire while still leaving them as resolvable
  paths in the tree.

  Two helpers wrap `set_sync/3` for readability:

    - `activate/2` flips the flag on (entry resumes syncing)
    - `deactivate/2` flips the flag off (entry parks locally)

  New entries default to `sync: true` (no `:nosync` suffix). Only
  explicit toggles via `set_sync/3` flip them off.

  ## Public surface

    - `new_schema/0` — fresh empty schema with both YMaps
      registered and `version` set.
    - `version/1` — read schema version (currently always `1`).
    - `add_file/3`, `add_directory/3` — write entries with the right
      `type` tag.
    - `remove_entry/2` — delete by name; standard YMap key delete.
    - `entries/1` — raw `%{name => %{"type", "node_id", "sync"}}`
      map for callers that want a flat dump.
    - `get_entry/2`, `list_entries/1` — `%Entry{}`-shaped views.
    - `set_sync/3`, `activate/2`, `deactivate/2` — sync-flag toggles.
    - `resolve_name/2` — `name → node_id`, the projection used by
      tree walks that don't care about type or sync metadata.
    - `honorific_extension?/1`, `forbid_honorific!/1` — the
      reserved-extension guard documented above.

  ## Invariants

    - Entry names are unique within a directory (YMap key uniqueness;
      concurrent writes resolve by Yjs LWW).
    - Encoded values round-trip through `decode_entry/1` losslessly.
    - The `"schema"` and `"entries"` types are always registered
      after any operation (`ensure_types/1` is defensive against
      docs that arrive without them, e.g. via `apply_update`).
    - `sync: true` is the default; only explicit `set_sync/3`
      toggles flip it off.

  ## What this module is NOT

  - **Not a path resolver** — that's `Commonplace.Tree.Walk` /
    `Commonplace.Tree.Lookup`. Schema only resolves single-name
    entries within one directory.
  - **Not a fork** — `Commonplace.Tree.Fork` deep-copies subtrees
    and produces a `ForkManifest`; this module supplies the per-
    directory primitive Fork composes.
  - **Not the file-system sync agent** — it sets the sync flag;
    the agent reads it.
  - **Not a writer of presence files** — `Commonplace.Presence` is
    the trusted write path for honorific entries.
  """

  alias Yelixer.{Doc, Types.YMap}

  @schema_type "schema"
  @entries_type "entries"

  defmodule Entry do
    @moduledoc """
    A single entry in a schema document — the decoded form of one
    `entries[name]` value. The `type` field is normalized to atoms
    (`:doc` or `:dir`) for pattern-matching ergonomics; the wire
    form keeps the lowercase strings.
    """
    defstruct [:name, :type, :node_id, sync: true]

    @type t :: %__MODULE__{
            name: String.t(),
            type: :doc | :dir,
            node_id: String.t(),
            sync: boolean()
          }
  end

  @doc """
  Returns a fresh empty schema doc — both YMaps registered, version
  set to `"1"`. Use this as the starting point when minting a new
  directory; subsequent `add_file/3` / `add_directory/3` calls
  populate the `entries` map.
  """
  def new_schema do
    doc = Doc.new()
    {doc, _} = Doc.get_or_create_type(doc, @schema_type, :map)
    {doc, _} = Doc.get_or_create_type(doc, @entries_type, :map)
    doc = YMap.set(doc, @schema_type, "version", "1")
    doc
  end

  @doc "Get the schema version."
  def version(doc) do
    doc = ensure_types(doc)

    case YMap.get(doc, @schema_type, "version") do
      nil -> nil
      v when is_binary(v) -> String.to_integer(v)
      v -> v
    end
  end

  @honorific_extensions ~w(.bot .exe .usr .who)

  @doc """
  Return true iff `name` ends in one of the reserved honorific
  extensions: `.bot`, `.exe`, `.usr`, `.who` (CX-edy). The comparison
  is case-insensitive.

  Honorific extensions are reserved for presence documents — files
  that advertise an actor's live existence. The
  `Commonplace.Presence` module is the only trusted path for creating
  them; any user-facing write path must refuse to place new entries
  with these extensions, or an attacker could double-publish presence
  and break the single-presence-location invariant.
  """
  @spec honorific_extension?(String.t()) :: boolean()
  def honorific_extension?(name) when is_binary(name) do
    lower = String.downcase(name)
    Enum.any?(@honorific_extensions, &String.ends_with?(lower, &1))
  end

  @doc """
  Raise `ArgumentError` when `name` ends in a reserved honorific
  extension (CX-edy). Call this at untrusted write entrypoints (CLI
  ln, CLI import, future presence.move MCP tool) before adding
  user-provided names to the schema.
  """
  @spec forbid_honorific!(String.t()) :: :ok
  def forbid_honorific!(name) when is_binary(name) do
    if honorific_extension?(name) do
      raise ArgumentError,
            "reserved honorific extension in #{inspect(name)}: " <>
              ".bot / .exe / .usr / .who are reserved for presence documents " <>
              "(see Commonplace.Presence)"
    else
      :ok
    end
  end

  @doc """
  Adds a file entry. Defaults to `sync: true`. Does NOT call
  `forbid_honorific!/1` — callers that need the guard (untrusted
  write paths) must invoke it explicitly.
  """
  def add_file(doc, name, node_id) when is_binary(name) and is_binary(node_id) do
    add_entry(doc, name, "doc", node_id)
  end

  @doc """
  Adds a directory entry. Same shape as `add_file/3` — `sync: true`
  default; honorific guard is opt-in.
  """
  def add_directory(doc, name, node_id) when is_binary(name) and is_binary(node_id) do
    add_entry(doc, name, "dir", node_id)
  end

  @doc """
  Removes an entry by name. The underlying `YMap.delete/3` clears
  the key; concurrent re-adds from another replica resolve by Yjs
  LWW per key (no tombstone-blocks-set rule — same shape as the
  Beads dependency-edge semantics in §5.4 of beads-on-commonplace).
  """
  def remove_entry(doc, name) when is_binary(name) do
    doc = ensure_types(doc)
    YMap.delete(doc, @entries_type, name)
  end

  @doc "Get all entries as a raw map of {name => %{type, node_id}}."
  def entries(doc) do
    doc = ensure_types(doc)
    raw = YMap.to_map(doc, @entries_type)

    Map.new(raw, fn {name, value} ->
      case value do
        v when is_binary(v) ->
          {type, node_id, sync} = decode_entry(v)
          {name, %{"type" => type, "node_id" => node_id, "sync" => sync}}

        _ ->
          {name, %{}}
      end
    end)
  end

  @doc "Get a single entry by name."
  def get_entry(doc, name) when is_binary(name) do
    all = entries(doc)

    case Map.get(all, name) do
      nil ->
        :error

      entry_map ->
        {:ok,
         %Entry{
           name: name,
           type: parse_type(entry_map["type"]),
           node_id: entry_map["node_id"],
           sync: Map.get(entry_map, "sync", true)
         }}
    end
  end

  @doc "List all entries as Entry structs."
  def list_entries(doc) do
    entries(doc)
    |> Enum.map(fn {name, entry_map} ->
      %Entry{
        name: name,
        type: parse_type(entry_map["type"]),
        node_id: entry_map["node_id"],
        sync: Map.get(entry_map, "sync", true)
      }
    end)
  end

  @doc "Set the sync flag on an entry (activate/deactivate)."
  def set_sync(doc, name, sync) when is_binary(name) and is_boolean(sync) do
    doc = ensure_types(doc)
    all = entries(doc)

    case Map.get(all, name) do
      nil ->
        doc

      entry_map ->
        type = entry_map["type"]
        node_id = entry_map["node_id"]
        YMap.set(doc, @entries_type, name, encode_entry(type, node_id, sync))
    end
  end

  @doc "Activate a branch (set sync:true)."
  def activate(doc, name), do: set_sync(doc, name, true)

  @doc "Deactivate a branch (set sync:false)."
  def deactivate(doc, name), do: set_sync(doc, name, false)

  @doc "Resolve a name to its node_id."
  def resolve_name(doc, name) when is_binary(name) do
    case get_entry(doc, name) do
      {:ok, entry} -> {:ok, entry.node_id}
      :error -> :error
    end
  end

  # --- Private ---

  defp add_entry(doc, name, type, node_id) do
    doc = ensure_types(doc)
    doc = YMap.set(doc, @entries_type, name, encode_entry(type, node_id, true))
    doc
  end

  # Codec for the entry-value string. Only place in this module that
  # knows the wire shape; everything else goes through these.
  #
  # The `:` delimiter is safe because UUIDs are hex+dashes (no
  # colons) and our type tags are word-only ("doc" / "dir"). The
  # third arm of decode_entry handles a legacy two-token form where
  # the entry string was just a raw UUID with no type tag — that
  # shape predates the encoded-string scheme and survives only as a
  # decode fallback for old-format updates that are still in the
  # wild.
  defp encode_entry(type, node_id, true), do: "#{type}:#{node_id}"
  defp encode_entry(type, node_id, false), do: "#{type}:#{node_id}:nosync"

  defp decode_entry(encoded) when is_binary(encoded) do
    case String.split(encoded, ":") do
      [type, node_id, "nosync"] -> {type, node_id, false}
      [type, node_id] -> {type, node_id, true}
      _ -> {"doc", encoded, true}
    end
  end

  defp ensure_types(doc) do
    doc =
      if Doc.has_type?(doc, @schema_type) do
        doc
      else
        {doc, _} = Doc.get_or_create_type(doc, @schema_type, :map)
        doc
      end

    if Doc.has_type?(doc, @entries_type) do
      doc
    else
      {doc, _} = Doc.get_or_create_type(doc, @entries_type, :map)
      doc
    end
  end

  defp parse_type("doc"), do: :doc
  defp parse_type("dir"), do: :dir
  defp parse_type(_), do: :unknown
end

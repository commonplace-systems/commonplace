defmodule Commonplace.Tree.Schema do
  @moduledoc """
  Directory-as-CRDT — the substrate atom for Commonplace's tree.

  A schema doc *is* a directory: it maps child names to the UUIDs of
  other docs (files or sub-directories), with per-child sync metadata.
  Walking a path through Commonplace's tree means traversing a chain of
  schema docs, one per directory level.

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
  schema docs. Every doc tree in the workspace bottoms out in schemas;
  everything else (text, JSON metadata, presence files, binaries) is a
  *leaf* referenced by UUID from a schema's `entries`.

  ## Why two top-level YMaps

  A `Yelixer.Doc` (the underlying Yjs document wrapper) can hold
  multiple named top-level shared types. `"schema"` holds meta-state
  that belongs to the directory itself — currently just `"version"`,
  with room for root config and future evolution. `"entries"` holds the
  directory's actual contents. Separating them prevents meta-keys from
  colliding with user-chosen child names: a directory with a child named
  `"version"` would conflict if meta lived in the same YMap.

  ## The encoded entry value: `"type:uuid[:nosync]"`

  Each `entries[name]` value is a plain string. The format is:

      "doc:<uuid>"          — file entry, sync enabled
      "dir:<uuid>"          — directory entry, sync enabled
      "doc:<uuid>:nosync"   — file entry, sync disabled
      "dir:<uuid>:nosync"   — directory entry, sync disabled

  Why a string rather than a nested YMap? Three reasons:

    1. **Yelixer YMap values are scalars.** A nested YMap could be
       expressed using `Yelixer.Doc`'s `__sub:CLIENT:CLOCK` sub-type
       naming scheme, but that costs a separate type registration and an
       extra doc-shape entry per child. At Commonplace's scale —
       thousands of directories, thousands of entries — the overhead
       compounds.
    2. **YMap last-write-wins (LWW) per key gives clean concurrent
       semantics for free.** Two replicas concurrently writing the same
       child name resolve via Yjs's `(Lamport-clock, clientID)` tiebreak,
       identical to any other YMap key. A structured value would require
       independent LWW on each sub-field, which is wrong: a directory
       entry is one logical value, not a record of independently editable
       fields.
    3. **The `:` delimiter is unambiguous.** UUIDs are hex digits and
       dashes (no colons); type tags are `"doc"` and `"dir"` (no
       colons); `"nosync"` is a fixed token. `String.split/2` round-trips
       cleanly without escaping logic.

  `encode_entry/3` and `decode_entry/1` are the sole codec; all reads
  and writes in this module go through them. A legacy bare-UUID form
  (pre-dating this scheme — entries that were just a raw UUID with
  no type tag) is still decoded for backward compatibility with old
  updates that may surface via `apply_update/2`; `decode_entry/1`'s
  third arm handles it by treating the UUID as a `"doc"` entry with
  sync enabled.

  ## Honorific extensions and the presence-uniqueness invariant (CX-edy)

  Four file extensions are reserved as **honorifics** — markers that a
  file is a *presence document*, advertising the live existence of an
  actor in the workspace:

      .bot   .exe   .usr   .who

  The *single-presence-location invariant* requires that an actor's
  presence file (e.g. `alice.usr`) exists at exactly one path in the
  tree. This invariant lets cross-cluster presence queries terminate; if
  it broke, a buggy CLI or an attacker (the CX-edy threat model) could
  double-publish a presence file at two locations under the same actor
  name, corrupting every query that relies on uniqueness.

  `forbid_honorific!/1` is the **opt-in guard** that untrusted write
  entrypoints (CLI `ln`, CLI `import`, future MCP tools) must call
  before adding user-provided names. Trusted internal callers —
  `Commonplace.Presence.create/3` and `Presence.move/3` — bypass the
  guard because they *are* the canonical path for honorific files. The
  check is case-insensitive (`Foo.USR` and `bar.Usr` are both rejected)
  so casing tricks cannot circumvent it.

  The guard lives *here* because this module is the chokepoint for all
  directory mutations. Anywhere else, an attacker could add a `.usr`
  entry by going around it.

  ## The sync flag and branch deactivation

  The `:nosync` suffix is a per-entry flag meaning "omit me when
  computing sync subscriptions." The sync agent subscribes to path
  prefixes the workspace's local config wants to mirror; the flag lets
  deactivated branches stay off the wire while remaining resolvable
  paths in the tree.

  Two helpers wrap `set_sync/3` for readability:

    - `activate/2` — sets the flag to `true`; the entry resumes syncing.
    - `deactivate/2` — sets the flag to `false`; the entry parks locally.

  New entries default to `sync: true` (no `:nosync` suffix). Only
  explicit calls to `set_sync/3` change the flag.

  ## Public surface

    - `new_schema/0` — fresh empty schema doc with both YMaps registered
      and `version` set to `"1"`.
    - `version/1` — read the schema version (currently always `1`).
    - `add_file/3`, `add_directory/3` — write entries with the correct
      type tag; both default to `sync: true`.
    - `remove_entry/2` — delete an entry by name via YMap key delete.
    - `entries/1` — raw `%{name => %{"type", "node_id", "sync"}}` map
      for callers that need a flat dump.
    - `get_entry/2`, `list_entries/1` — `%Entry{}`-shaped views.
    - `set_sync/3`, `activate/2`, `deactivate/2` — sync-flag toggles.
    - `resolve_name/2` — maps a child name to its `node_id`; the
      projection used by tree walks that don't need type or sync
      metadata.
    - `honorific_extension?/1`, `forbid_honorific!/1` — the
      reserved-extension guard described above.

  ## Invariants

    - Entry names are unique within a directory (YMap key uniqueness;
      concurrent writes resolve by Yjs LWW).
    - Encoded values round-trip through `decode_entry/1` losslessly.
    - `"schema"` and `"entries"` YMap types are always present after any
      operation; `ensure_types/1` is defensive against docs that arrive
      without them (e.g. via `apply_update`). All public reads
      (`entries/1`, `version/1`, `set_sync/3`, `remove_entry/2`)
      internally call `ensure_types/1` so callers can hand in a
      freshly-applied doc without first wondering whether the
      registrations made it across the wire.
    - `sync: true` is the default; only explicit `set_sync/3` calls
      change it.

  ## What this module is NOT

  - **Not a path resolver** — that is `Commonplace.Tree.Walk` and
    `Commonplace.Tree.Lookup`. Schema resolves single child-name lookups
    within one directory only.
  - **Not a fork** — `Commonplace.Tree.Fork` deep-copies subtrees and
    produces a `ForkManifest`; this module is the per-directory primitive
    that Fork composes.
  - **Not the sync agent** — it sets the sync flag; the agent reads it.
  - **Not a writer of presence files** — `Commonplace.Presence` is the
    trusted write path for honorific entries.
  """

  alias Yelixer.{Doc, Types.YMap}

  @schema_type "schema"
  @entries_type "entries"

  defmodule Entry do
    @moduledoc """
    Decoded form of one `entries[name]` value. `type` is normalized
    to atoms (`:doc` or `:dir`) for pattern-matching ergonomics;
    the wire format uses the lowercase strings `"doc"` and `"dir"`.
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
  Returns a fresh empty schema doc with both YMaps registered and
  `version` set to `"1"`. Use this as the starting point when
  creating a new directory; subsequent `add_file/3` and
  `add_directory/3` calls populate `entries`.
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
  Returns `true` when `name` ends in one of the four reserved
  honorific extensions: `.bot`, `.exe`, `.usr`, `.who`. Check is
  case-insensitive. See the `@moduledoc` for the CX-edy threat model
  and the single-presence-location invariant this guard protects.
  """
  @spec honorific_extension?(String.t()) :: boolean()
  def honorific_extension?(name) when is_binary(name) do
    lower = String.downcase(name)
    Enum.any?(@honorific_extensions, &String.ends_with?(lower, &1))
  end

  @doc """
  Raises `ArgumentError` when `name` ends in a reserved honorific
  extension. Call this at untrusted write entrypoints — CLI `ln`,
  CLI `import`, future MCP tools — before adding user-provided names
  to the schema. Trusted callers (`Commonplace.Presence`) bypass it.
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
  Adds a file entry with `sync: true`. Does not call
  `forbid_honorific!/1` — untrusted write paths must invoke that
  guard explicitly before calling this.
  """
  def add_file(doc, name, node_id) when is_binary(name) and is_binary(node_id) do
    add_entry(doc, name, "doc", node_id)
  end

  @doc """
  Adds a directory entry with `sync: true`. Same contract as
  `add_file/3`: the honorific guard is opt-in for callers.
  """
  def add_directory(doc, name, node_id) when is_binary(name) and is_binary(node_id) do
    add_entry(doc, name, "dir", node_id)
  end

  @doc """
  Removes an entry by name via `YMap.delete/3`. Concurrent re-adds
  from another replica resolve by Yjs LWW per key — no
  tombstone-blocks-set rule (same semantics as Beads dependency
  edges, §5.4 of beads-on-commonplace).
  """
  def remove_entry(doc, name) when is_binary(name) do
    doc = ensure_types(doc)
    YMap.delete(doc, @entries_type, name)
  end

  @doc "Returns all entries as `%{name => %{\"type\", \"node_id\", \"sync\"}}`."
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

  @doc "Returns a single `%Entry{}` by name, or `:error` if absent."
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

  @doc "Returns all entries as a list of `%Entry{}` structs."
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

  @doc "Sets the sync flag on a named entry. No-op if the entry does not exist."
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

  @doc "Marks the entry as syncing (`sync: true`). Shorthand for `set_sync/3`."
  def activate(doc, name), do: set_sync(doc, name, true)

  @doc "Marks the entry as local-only (`sync: false`). Shorthand for `set_sync/3`."
  def deactivate(doc, name), do: set_sync(doc, name, false)

  @doc "Maps a child name to its `node_id`, discarding type and sync metadata."
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

  # Sole codec for the entry-value string. All reads and writes pass
  # through here — no other function knows the wire shape.
  #
  # The third arm of decode_entry handles a legacy bare-UUID form
  # (no type tag) that predates the encoded-string scheme; it
  # survives as a fallback for old-format updates still in the wild.
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

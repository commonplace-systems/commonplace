defmodule Commonplace.Presence do
  @moduledoc """
  Presence documents — actor "business cards" in the document tree.

  Every actor (a process, a human, an AI agent) advertises its existence
  by owning a presence document: a small CRDT map, stored like any other
  document and registered as a file in a parent directory's schema. The
  filename encodes the actor's TYPE via an **honorific extension**:

    * `.exe` — a process
    * `.usr` — a human
    * `.bot` — an AI agent
    * `.who` — generic / unspecified

  (`parse_honorific/1` and `filename/2` convert between `name` + type and
  the on-disk filename; `discover/2` lists the actors of a given type in a
  schema.) The map carries the actor's live state — `name`, `type`,
  `status`, `started_at`, a `heartbeat` timestamp refreshed by
  `heartbeat/2`, and optional `activity` / `owner` / `cwd` /
  `capabilities` attributes — so presence doubles as a liveness signal: a
  fresh heartbeat says the actor is still alive, a stale one says it is
  probably gone.

  ## Single-writer invariant (load-bearing)

  Every write to a presence doc (create, status update, heartbeat,
  restart) reconstructs it under a *stable* `client_id` derived from the
  doc's uuid (`:erlang.phash2`). This keeps the Yjs state vector at one
  client slot instead of minting a fresh random client per write —
  without it the SV grows unbounded, O(N) in the number of writes
  (CX-3ty / CX-6g6).

  That sharing is safe **only because a presence doc is semantically
  single-writer**: an actor owns its own `.bot` / `.usr` / `.exe` /
  `.who` file and no one else writes to it. If two distinct writers
  shared a `client_id` on the same doc from the same base state,
  `YMap.set` would mint identical `(client_id, clock)` pairs and
  `Encoding.apply_update` would silently drop one side as "already
  known." Anyone adding a *shared* presence-like document must NOT reuse
  this scheme — see `Commonplace.Presence.Identity`, which faces exactly
  this and solves it differently.
  """

  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType
  alias Commonplace.MUD.SignedWrite
  alias Commonplace.Store.CommitStoreClient

  @honorifics %{
    "exe" => :exe,
    "usr" => :usr,
    "bot" => :bot,
    "who" => :who
  }

  @type_to_ext %{
    exe: "exe",
    usr: "usr",
    bot: "bot",
    who: "who"
  }

  @doc "Returns the type-to-extension map."
  def type_to_ext, do: @type_to_ext

  @doc "Parse a filename into {name, type}."
  def parse_honorific(filename) do
    case Path.extname(filename) do
      "." <> ext ->
        case Map.get(@honorifics, ext) do
          nil -> :error
          type -> {:ok, Path.rootname(filename), type}
        end

      _ ->
        :error
    end
  end

  @doc "Build a filename from name and type."
  def filename(name, type) do
    "#{name}.#{Map.fetch!(@type_to_ext, type)}"
  end

  @doc """
  Create a presence document and add it to the parent schema.

  `opts` (CX-0a9a, presence-carve plumbing — additive, defaults reproduce
  today's unsigned behavior EXACTLY):

    * `:signing_context` — a `%Commonplace.Crypto.SigningContext{}` or
      `nil` (default). `nil` means both commits this function produces
      (the presence-doc commit and the parent-schema entry commit) stay
      unsigned, exactly as before.
    * `:cert_cids` — capability CIDs the writer holds (default `[]`),
      consulted by `Commonplace.MUD.SignedWrite.opts_for/2` to attach a
      `capability_proof` to each commit.
    * `:signer_id` — the writer's identity uuid. When present, ALSO
      written into the presence doc as `"bound_identity"` — the field
      the presence-carve content-check (W3) identity-matches against.
      Absent (the default / anonymous path) → the field is omitted
      entirely, not set to nil, preserving back-compat for every reader
      that doesn't expect the key.
  """
  def create(name, type, dir_uuid, store \\ CommitStoreClient, opts \\ []) do
    fname = filename(name, type)

    # Check for collision
    dir_doc = load_schema(dir_uuid, store)
    fname = resolve_collision(dir_doc, fname, name, type)

    # Create the presence document
    uuid = UUID.uuid4()
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    doc = Yelixer.Doc.new(client_id: stable_client_id(uuid))
    doc = ContentType.create(doc, :map, fname)
    doc = ContentType.set_key(doc, "name", name)
    doc = ContentType.set_key(doc, "type", Map.fetch!(@type_to_ext, type))
    doc = ContentType.set_key(doc, "status", "starting")
    doc = ContentType.set_key(doc, "started_at", now)
    doc = ContentType.set_key(doc, "heartbeat", now)

    # CX-0a9a (W4): bind the presence doc to the writer's BARE identity
    # uuid (the stable cryptographic principal), taken from the signing
    # context — NOT the composite `signer_id` (which folds in a key
    # fingerprint). The presence-carve's `{:presence, id}` cert scope and
    # W3 content-check both compare against this bare identity uuid, so
    # binding to the composite signer_id would make every own-presence
    # write fail the carve. Omitted entirely on the anonymous/unsigned
    # path (no signing context), preserving back-compat.
    doc =
      case Keyword.get(opts, :signing_context) do
        %{identity_uuid: bound_id} when is_binary(bound_id) ->
          ContentType.set_key(doc, "bound_identity", bound_id)

        _ ->
          doc
      end

    update = Yelixer.Encoding.encode_update(doc)
    {metadata, commit_opts} = SignedWrite.opts_for(uuid, Keyword.put(opts, :store, store))

    with %Commonplace.Store.Commit{} <-
           CommitStoreClient.create_commit(store, uuid, update, nil, metadata, commit_opts) do
      # Add to parent schema only after the presence document landed. This
      # prevents a denied genesis write from producing a dangling tree entry.
      dir_doc = load_schema(dir_uuid, store)
      dir_doc = Schema.add_file(dir_doc, fname, uuid)
      update = Yelixer.Encoding.encode_update(dir_doc)

      {dir_metadata, dir_commit_opts} =
        SignedWrite.opts_for(dir_uuid, Keyword.put(opts, :store, store))

      case CommitStoreClient.create_chained_commit(
             store,
             dir_uuid,
             update,
             dir_metadata,
             dir_commit_opts
           ) do
        %Commonplace.Store.Commit{} -> {:ok, uuid}
        {:error, _reason} = error -> error
      end
    else
      {:error, _reason} = error -> error
    end
  end

  @doc "Read the presence document contents."
  def read(uuid, store \\ CommitStoreClient) do
    case CommitStoreClient.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Yelixer.Doc.new()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        ContentType.get_content(doc)

      :none ->
        nil
    end
  end

  @doc """
  Update the status field of a presence document.

  `opts` — same `:signing_context` / `:cert_cids` shape as `create/5` /
  `heartbeat/3` (CX-i9w9). Default `[]` reproduces the prior unsigned write
  (denied under `:enforce`); a signed caller lands via the CX-0a9a carve.
  """
  def update_status(uuid, status, store \\ CommitStoreClient, opts \\ []) do
    doc = load_doc(uuid, store)
    doc = ContentType.set_key(doc, "status", status)
    update = Yelixer.Encoding.encode_update(doc)
    {metadata, commit_opts} = SignedWrite.opts_for(uuid, Keyword.put(opts, :store, store))
    CommitStoreClient.create_chained_commit(store, uuid, update, metadata, commit_opts)
  end

  @doc """
  Update the heartbeat timestamp.

  `opts` — same `:signing_context` / `:cert_cids` shape as `create/5`
  (CX-0a9a plumbing); default `[]` reproduces today's unsigned behavior.
  """
  def heartbeat(uuid, store \\ CommitStoreClient, opts \\ []) do
    doc = load_doc(uuid, store)
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    doc = ContentType.set_key(doc, "heartbeat", now)
    update = Yelixer.Encoding.encode_update(doc)
    {metadata, commit_opts} = SignedWrite.opts_for(uuid, Keyword.put(opts, :store, store))
    CommitStoreClient.create_chained_commit(store, uuid, update, metadata, commit_opts)
  end

  @doc "Discover actors by type in a schema document."
  def discover(schema_doc, type) do
    Schema.list_entries(schema_doc)
    |> Enum.filter(fn entry ->
      case parse_honorific(entry.name) do
        {:ok, _, actor_type} ->
          type == :all or actor_type == type

        :error ->
          false
      end
    end)
  end

  @doc """
  Remove a presence entry from the parent schema.

  `opts` — same `:signing_context` / `:cert_cids` shape as `create/5`
  (CX-0a9a plumbing); default `[]` reproduces today's unsigned behavior.
  """
  def remove(fname, dir_uuid, store \\ CommitStoreClient, opts \\ []) do
    dir_doc = load_schema(dir_uuid, store)
    dir_doc = Schema.remove_entry(dir_doc, fname)
    update = Yelixer.Encoding.encode_update(dir_doc)
    {metadata, commit_opts} = SignedWrite.opts_for(dir_uuid, Keyword.put(opts, :store, store))
    CommitStoreClient.create_chained_commit(store, dir_uuid, update, metadata, commit_opts)
  end

  defp resolve_collision(dir_doc, fname, name, type) do
    case Schema.get_entry(dir_doc, fname) do
      :error ->
        fname

      {:ok, _} ->
        # Collision — add hash suffix
        hash = :erlang.phash2({name, System.monotonic_time()}, 0xFFF)
        suffix = Integer.to_string(hash, 16) |> String.downcase()
        "#{name}-#{suffix}.#{Map.fetch!(@type_to_ext, type)}"
    end
  end

  defp load_schema(uuid, store) do
    case CommitStoreClient.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end

  defp load_doc(uuid, store) do
    case CommitStoreClient.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Yelixer.Doc.new(client_id: stable_client_id(uuid))
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        doc = Yelixer.Doc.new(client_id: stable_client_id(uuid))
        ContentType.create(doc, :map, "presence")
    end
  end

  # Derive a stable client_id from the presence UUID so all writers (heartbeat,
  # status updates, restarts) on a SINGLE presence doc reuse the same Yjs
  # client_id. Without this, each Yelixer.Doc.new() call mints a fresh random
  # client_id which gets persisted into the state vector on encode_update,
  # causing unbounded O(N) state-vector growth (see CX-3ty / CX-6g6).
  #
  # SINGLE-WRITER INVARIANT: this is safe ONLY because presence docs are
  # semantically single-writer. An actor owns its own .bot/.usr/.exe/.who
  # file; no one else writes to it. If two distinct writers shared a
  # client_id on the same doc from the same base state, YMap.set/4 would
  # assign identical (client_id, clock) pairs and Encoding.apply_update/2
  # would silently drop one side of concurrent updates as "already known".
  #
  # For SHARED docs (e.g. identity docs in Commonplace.Presence.Identity),
  # this invariant does NOT hold — see that module for its own scheme.
  defp stable_client_id(uuid), do: :erlang.phash2(uuid, 0xFFFF_FFFF)

  @doc """
  Set the `activity` field on a presence YMap.

  Actor harnesses (commonplaceclaude, MCP server, etc.) call this to push
  a free-form "current task" string that the wiki presence card surfaces.

  Writes a single chained commit on the presence document. Pass `nil` or
  the empty string to clear the field — both are stored as-is so callers
  can distinguish "no activity" from "never set".

  `opts` — same `:signing_context` / `:cert_cids` shape as `create/5` /
  `update_status/4` (CX-i9w9 / CX-l5js); default `[]` reproduces today's
  unsigned behavior (denied under `:enforce`).
  """
  def set_activity(uuid, activity, store \\ CommitStoreClient, opts \\ [])
      when is_binary(uuid) do
    doc = load_doc(uuid, store)
    value = if is_nil(activity), do: "", else: to_string(activity)
    doc = ContentType.set_key(doc, "activity", value)
    update = Yelixer.Encoding.encode_update(doc)
    {metadata, commit_opts} = SignedWrite.opts_for(uuid, Keyword.put(opts, :store, store))
    CommitStoreClient.create_chained_commit(store, uuid, update, metadata, commit_opts)
  end

  @doc """
  Write a batch of optional presence attributes in a single chained commit.

  Accepts a map (or keyword list) with any of the following keys (all
  optional — unsupplied keys are not written):

    * `:owner` — string, who launched this actor (user/process name).
    * `:cwd` — string, working directory / project root at start time.
    * `:capabilities` — list of strings, tool/MCP/skill names. Stored as
      a JSON-encoded string so it survives YMap's scalar-value constraint
      and round-trips through `read/2` cleanly.

  Unknown keys are ignored (logged at debug). Returns the commit struct
  from `CommitStoreClient.create_chained_commit/3`.

  This function is split out from `create/2` deliberately — it lets
  callers populate owner/cwd/capabilities at start-up time without
  expanding the `create/2` signature, keeping the write surface
  composable for tests and CLI harnesses.

  `opts` — same `:signing_context` / `:cert_cids` shape as `create/5` /
  `update_status/4` (CX-i9w9 / CX-l5js); default `[]` reproduces today's
  unsigned behavior (denied under `:enforce`).
  """
  def set_attributes(uuid, attrs, store \\ CommitStoreClient, opts \\ []) when is_binary(uuid) do
    attrs = if is_list(attrs), do: Enum.into(attrs, %{}), else: attrs
    doc = load_doc(uuid, store)

    doc =
      Enum.reduce(attrs, doc, fn {key, value}, acc ->
        # CX-rlv: normalize keys so the same clauses match regardless of
        # whether attrs arrived as atom-keyed (Elixir-internal) or
        # string-keyed (parsed JSON / RPC params).
        case normalize_key(key) do
          :owner when is_binary(value) ->
            ContentType.set_key(acc, "owner", value)

          :cwd when is_binary(value) ->
            ContentType.set_key(acc, "cwd", value)

          :capabilities when is_list(value) ->
            encoded = Jason.encode!(Enum.map(value, &to_string/1))
            ContentType.set_key(acc, "capabilities", encoded)

          _ ->
            require Logger

            Logger.debug(
              "Presence.set_attributes: ignoring unknown/typed key #{inspect(key)}=#{inspect(value)}"
            )

            acc
        end
      end)

    update = Yelixer.Encoding.encode_update(doc)
    {metadata, commit_opts} = SignedWrite.opts_for(uuid, Keyword.put(opts, :store, store))
    CommitStoreClient.create_chained_commit(store, uuid, update, metadata, commit_opts)
  end

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key("owner"), do: :owner
  defp normalize_key("cwd"), do: :cwd
  defp normalize_key("capabilities"), do: :capabilities
  defp normalize_key(other), do: other
end

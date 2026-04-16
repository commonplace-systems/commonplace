defmodule Commonplace.Presence do
  @moduledoc """
  Presence files — actor business cards in the document tree.

  Actors advertise their existence via presence documents with
  honorific extensions: .exe (process), .usr (human), .bot (AI), .who (generic).
  """

  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType
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

  @doc "Create a presence document and add it to the parent schema."
  def create(name, type, dir_uuid, store \\ CommitStoreClient) do
    fname = filename(name, type)

    # Check for collision
    dir_doc = load_schema(dir_uuid, store)
    fname = resolve_collision(dir_doc, fname, name, type)

    # Create the presence document
    uuid = UUID.uuid4()
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :map, fname)
    doc = ContentType.set_key(doc, "name", name)
    doc = ContentType.set_key(doc, "type", Map.fetch!(@type_to_ext, type))
    doc = ContentType.set_key(doc, "status", "starting")
    doc = ContentType.set_key(doc, "started_at", now)
    doc = ContentType.set_key(doc, "heartbeat", now)

    update = Yelixer.Encoding.encode_update(doc)
    CommitStoreClient.create_commit(store, uuid, update, nil)

    # Add to parent schema
    dir_doc = load_schema(dir_uuid, store)
    dir_doc = Schema.add_file(dir_doc, fname, uuid)
    update = Yelixer.Encoding.encode_update(dir_doc)
    CommitStoreClient.create_chained_commit(store, dir_uuid, update)

    {:ok, uuid}
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

  @doc "Update the status field of a presence document."
  def update_status(uuid, status, store \\ CommitStoreClient) do
    doc = load_doc(uuid, store)
    doc = ContentType.set_key(doc, "status", status)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStoreClient.create_chained_commit(store, uuid, update)
  end

  @doc "Update the heartbeat timestamp."
  def heartbeat(uuid, store \\ CommitStoreClient) do
    doc = load_doc(uuid, store)
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    doc = ContentType.set_key(doc, "heartbeat", now)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStoreClient.create_chained_commit(store, uuid, update)
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

  @doc "Remove a presence entry from the parent schema."
  def remove(fname, dir_uuid, store \\ CommitStoreClient) do
    dir_doc = load_schema(dir_uuid, store)
    dir_doc = Schema.remove_entry(dir_doc, fname)
    update = Yelixer.Encoding.encode_update(dir_doc)
    CommitStoreClient.create_chained_commit(store, dir_uuid, update)
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
        doc = Yelixer.Doc.new()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        doc = Yelixer.Doc.new()
        ContentType.create(doc, :map, "presence")
    end
  end

  @doc """
  Set the `activity` field on a presence YMap.

  Actor harnesses (commonplaceclaude, MCP server, etc.) call this to push
  a free-form "current task" string that the wiki presence card surfaces.

  Writes a single chained commit on the presence document. Pass `nil` or
  the empty string to clear the field — both are stored as-is so callers
  can distinguish "no activity" from "never set".
  """
  def set_activity(uuid, activity, store \\ CommitStoreClient)
      when is_binary(uuid) do
    doc = load_doc(uuid, store)
    value = if is_nil(activity), do: "", else: to_string(activity)
    doc = ContentType.set_key(doc, "activity", value)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStoreClient.create_chained_commit(store, uuid, update)
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
  """
  def set_attributes(uuid, attrs, store \\ CommitStoreClient) when is_binary(uuid) do
    attrs = if is_list(attrs), do: Enum.into(attrs, %{}), else: attrs
    doc = load_doc(uuid, store)

    doc =
      Enum.reduce(attrs, doc, fn
        {:owner, owner}, acc when is_binary(owner) ->
          ContentType.set_key(acc, "owner", owner)

        {:cwd, cwd}, acc when is_binary(cwd) ->
          ContentType.set_key(acc, "cwd", cwd)

        {:capabilities, caps}, acc when is_list(caps) ->
          encoded = Jason.encode!(Enum.map(caps, &to_string/1))
          ContentType.set_key(acc, "capabilities", encoded)

        {key, _value}, acc ->
          require Logger
          Logger.debug("Presence.set_attributes: ignoring unknown key #{inspect(key)}")
          acc
      end)

    update = Yelixer.Encoding.encode_update(doc)
    CommitStoreClient.create_chained_commit(store, uuid, update)
  end
end

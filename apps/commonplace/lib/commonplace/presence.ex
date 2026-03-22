defmodule Commonplace.Presence do
  @moduledoc """
  Presence files — actor business cards in the document tree.

  Actors advertise their existence via presence documents with
  honorific extensions: .exe (process), .usr (human), .bot (AI), .who (generic).
  """

  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore

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
  def create(name, type, dir_uuid, store \\ CommitStore) do
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
    CommitStore.create_commit(store, uuid, update, nil)

    # Add to parent schema
    dir_doc = load_schema(dir_uuid, store)
    dir_doc = Schema.add_file(dir_doc, fname, uuid)
    update = Yelixer.Encoding.encode_update(dir_doc)
    CommitStore.create_commit(store, dir_uuid, update, nil)

    {:ok, uuid}
  end

  @doc "Read the presence document contents."
  def read(uuid, store \\ CommitStore) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Yelixer.Doc.new()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        ContentType.get_content(doc)

      :none ->
        nil
    end
  end

  @doc "Update the status field of a presence document."
  def update_status(uuid, status, store \\ CommitStore) do
    doc = load_doc(uuid, store)
    doc = ContentType.set_key(doc, "status", status)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
  end

  @doc "Update the heartbeat timestamp."
  def heartbeat(uuid, store \\ CommitStore) do
    doc = load_doc(uuid, store)
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    doc = ContentType.set_key(doc, "heartbeat", now)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
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
  def remove(fname, dir_uuid, store \\ CommitStore) do
    dir_doc = load_schema(dir_uuid, store)
    dir_doc = Schema.remove_entry(dir_doc, fname)
    update = Yelixer.Encoding.encode_update(dir_doc)
    CommitStore.create_commit(store, dir_uuid, update, nil)
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
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end

  defp load_doc(uuid, store) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Yelixer.Doc.new()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        doc = Yelixer.Doc.new()
        ContentType.create(doc, :map, "presence")
    end
  end
end

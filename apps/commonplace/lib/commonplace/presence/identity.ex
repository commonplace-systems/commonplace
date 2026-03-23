defmodule Commonplace.Presence.Identity do
  @moduledoc """
  Cold identity — permanent actor records in __identities__.

  Unlike hot presence files (which are created on start and deleted on
  shutdown), cold identities persist across restarts. They live in an
  `__identities__` system directory in the root schema.
  """

  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Commonplace.Presence

  @identities_dir "__identities__"

  @doc "Ensure the __identities__ system directory exists in the root schema."
  def ensure_identities_dir(root_uuid, store \\ CommitStore) do
    root_doc = load_schema(root_uuid, store)

    case Schema.get_entry(root_doc, @identities_dir) do
      {:ok, entry} ->
        {:ok, entry.node_id}

      :error ->
        # Create the identities directory schema doc
        dir_uuid = UUID.uuid4()
        dir_doc = Schema.new_schema()
        update = Yelixer.Encoding.encode_update(dir_doc)
        CommitStore.create_commit(store, dir_uuid, update, nil)

        # Add to root schema
        root_doc = load_schema(root_uuid, store)
        root_doc = Schema.add_directory(root_doc, @identities_dir, dir_uuid)
        update = Yelixer.Encoding.encode_update(root_doc)
        CommitStore.create_chained_commit(store, root_uuid, update)

        {:ok, dir_uuid}
    end
  end

  @doc "Register a cold identity. Creates if new, updates last_seen if existing."
  def register(name, type, root_uuid, store \\ CommitStore) do
    {:ok, id_dir_uuid} = ensure_identities_dir(root_uuid, store)
    fname = Presence.filename(name, type)

    id_doc = load_schema(id_dir_uuid, store)

    case Schema.get_entry(id_doc, fname) do
      {:ok, entry} ->
        # Existing identity — update last_seen
        touch_last_seen(entry.node_id, store)
        {:ok, entry.node_id}

      :error ->
        # New identity
        uuid = UUID.uuid4()
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        doc = Yelixer.Doc.new()
        doc = ContentType.create(doc, :map, fname)
        doc = ContentType.set_key(doc, "name", name)
        doc = ContentType.set_key(doc, "type", Map.fetch!(Presence.type_to_ext(), type))
        doc = ContentType.set_key(doc, "first_seen", now)
        doc = ContentType.set_key(doc, "last_seen", now)

        update = Yelixer.Encoding.encode_update(doc)
        CommitStore.create_commit(store, uuid, update, nil)

        # Add to identities schema
        id_doc = load_schema(id_dir_uuid, store)
        id_doc = Schema.add_file(id_doc, fname, uuid)
        update = Yelixer.Encoding.encode_update(id_doc)
        CommitStore.create_chained_commit(store, id_dir_uuid, update)

        {:ok, uuid}
    end
  end

  @doc "Read a cold identity document."
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

  @doc "Look up a cold identity by name and type."
  def lookup(name, type, root_uuid, store \\ CommitStore) do
    root_doc = load_schema(root_uuid, store)

    case Schema.get_entry(root_doc, @identities_dir) do
      :error ->
        :error

      {:ok, dir_entry} ->
        id_doc = load_schema(dir_entry.node_id, store)
        fname = Presence.filename(name, type)

        case Schema.get_entry(id_doc, fname) do
          {:ok, entry} -> {:ok, entry.node_id}
          :error -> :error
        end
    end
  end

  @doc "List all cold identities."
  def list(root_uuid, store \\ CommitStore) do
    root_doc = load_schema(root_uuid, store)

    case Schema.get_entry(root_doc, @identities_dir) do
      :error ->
        []

      {:ok, dir_entry} ->
        id_doc = load_schema(dir_entry.node_id, store)
        Schema.list_entries(id_doc)
    end
  end

  @doc "Update last_seen timestamp on a cold identity."
  def touch_last_seen(uuid, store \\ CommitStore) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Yelixer.Doc.new()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        now = DateTime.utc_now() |> DateTime.to_iso8601()
        doc = ContentType.set_key(doc, "last_seen", now)
        update = Yelixer.Encoding.encode_update(doc)
        CommitStore.create_chained_commit(store, uuid, update)

      :none ->
        :ok
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
end

defmodule Commonplace.Presence.Identity do
  @moduledoc """
  Cold identity — permanent actor records in __identities__.

  Unlike hot presence files (which are created on start and deleted on
  shutdown), cold identities persist across restarts. They live in an
  `__identities__` system directory in the root schema.
  """

  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Presence

  @identities_dir "__identities__"

  @doc "Ensure the __identities__ system directory exists in the root schema."
  def ensure_identities_dir(root_uuid, store \\ CommitStoreClient) do
    root_doc = load_schema(root_uuid, store)

    case Schema.get_entry(root_doc, @identities_dir) do
      {:ok, entry} ->
        {:ok, entry.node_id}

      :error ->
        # Create the identities directory schema doc
        dir_uuid = UUID.uuid4()
        dir_doc = Schema.new_schema()
        update = Yelixer.Encoding.encode_update(dir_doc)
        CommitStoreClient.create_commit(store, dir_uuid, update, nil)

        # Add to root schema
        root_doc = load_schema(root_uuid, store)
        root_doc = Schema.add_directory(root_doc, @identities_dir, dir_uuid)
        update = Yelixer.Encoding.encode_update(root_doc)
        CommitStoreClient.create_chained_commit(store, root_uuid, update)

        {:ok, dir_uuid}
    end
  end

  @doc "Register a cold identity. Creates if new, updates last_seen if existing."
  def register(name, type, root_uuid, store \\ CommitStoreClient) do
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

        doc = Yelixer.Doc.new(client_id: stable_client_id(uuid))
        doc = ContentType.create(doc, :map, fname)
        doc = ContentType.set_key(doc, "name", name)
        doc = ContentType.set_key(doc, "type", Map.fetch!(Presence.type_to_ext(), type))
        doc = ContentType.set_key(doc, "first_seen", now)
        doc = ContentType.set_key(doc, "last_seen", now)

        update = Yelixer.Encoding.encode_update(doc)
        CommitStoreClient.create_commit(store, uuid, update, nil)

        # Add to identities schema
        id_doc = load_schema(id_dir_uuid, store)
        id_doc = Schema.add_file(id_doc, fname, uuid)
        update = Yelixer.Encoding.encode_update(id_doc)
        CommitStoreClient.create_chained_commit(store, id_dir_uuid, update)

        {:ok, uuid}
    end
  end

  @doc "Read a cold identity document."
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

  @doc "Look up a cold identity by name and type."
  def lookup(name, type, root_uuid, store \\ CommitStoreClient) do
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
  def list(root_uuid, store \\ CommitStoreClient) do
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
  def touch_last_seen(uuid, store \\ CommitStoreClient) do
    case CommitStoreClient.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Yelixer.Doc.new(client_id: stable_client_id(uuid))
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        now = DateTime.utc_now() |> DateTime.to_iso8601()
        doc = ContentType.set_key(doc, "last_seen", now)
        update = Yelixer.Encoding.encode_update(doc)
        CommitStoreClient.create_chained_commit(store, uuid, update)

      :none ->
        :ok
    end
  end

  @doc "Add a public key to an identity document."
  def add_public_key(identity_uuid, public_key_b64, store \\ CommitStoreClient) do
    case CommitStoreClient.latest_commit(store, identity_uuid) do
      {:ok, commit} ->
        doc = Yelixer.Doc.new(client_id: stable_client_id(identity_uuid))
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)

        # Get existing keys or start empty
        content = ContentType.get_content(doc)

        keys =
          case content do
            %{"public_keys" => keys_json} when is_binary(keys_json) ->
              case Jason.decode(keys_json) do
                {:ok, list} when is_list(list) -> list
                _ -> []
              end

            _ ->
              []
          end

        unless public_key_b64 in keys do
          keys = keys ++ [public_key_b64]
          doc = ContentType.set_key(doc, "public_keys", Jason.encode!(keys))
          update = Yelixer.Encoding.encode_update(doc)
          CommitStoreClient.create_chained_commit(store, identity_uuid, update)
        end

        :ok

      :none ->
        {:error, :identity_not_found}
    end
  end

  @doc "Get public keys from an identity document."
  def get_public_keys(identity_uuid, store \\ CommitStoreClient) do
    case read(identity_uuid, store) do
      nil ->
        []

      content ->
        case content["public_keys"] do
          nil ->
            []

          keys_json ->
            case Jason.decode(keys_json) do
              {:ok, list} when is_list(list) -> list
              _ -> []
            end
        end
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

  # Derive a stable Yjs client_id for writes to a (shared) identity document.
  #
  # Identity docs live in __identities__ and are SHARED across all BEAM nodes
  # in a cluster: any node running a given actor (e.g. "sync.exe") can
  # concurrently register / touch_last_seen / add_public_key on the same
  # identity doc. That makes them a MULTI-WRITER document, unlike presence
  # docs.
  #
  # We therefore derive the client_id from BOTH the workspace's persistent
  # node-id and the identity UUID:
  #
  #   * Within a single workspace, writes to the same identity doc reuse
  #     the same client_id across BEAM restarts — so the state vector
  #     does NOT grow unboundedly across heartbeats / restarts (fixes the
  #     original CX-3ty / CX-6g6 state-vector-bloat regression). The
  #     persistent node-id (CX-njf, `Workspace.node_id/0`) replaces the
  #     prior `node()` atom, which changed across sname renames and IP
  #     reassignments and reintroduced the bloat at restart boundaries.
  #
  #   * Across distinct workspaces, node-ids differ — so if two concurrent
  #     updates from different installs are ever merged in memory via
  #     Encoding.apply_update/2, they carry distinct (client_id, clock)
  #     pairs and both survive instead of one being silently dropped as
  #     "already known".
  #
  # SCOPE — PREREQUISITE, NOT FULL MULTI-WRITER SAFETY.
  # Distinct client_ids are a *necessary precondition* for multi-writer CRDT
  # merge on identity docs, but they are NOT by themselves sufficient for
  # end-to-end multi-writer correctness through the CommitStore layer. The
  # write path here still follows:
  #
  #     latest_commit  ->  mutate in memory  ->  create_chained_commit
  #
  # and `Identity.read/2` reconstructs state from `latest_commit` only.
  # Under concurrent writes from two nodes racing on the same identity
  # UUID, both can observe the same parent commit, each produces a full
  # snapshot update, and both `create_chained_commit` calls succeed —
  # yielding two SIBLING commits chained to the same parent. The general
  # sibling-commit reconciliation lives in `Commonplace.SiblingMerger`
  # (CX-4qn1) for content docs; identity docs do not yet flow through
  # that primitive, but the present derivation is set up to compose with
  # it cleanly when they do.
  defp stable_client_id(uuid) do
    node_id =
      case Commonplace.Workspace.node_id() do
        {:ok, id} -> id
        {:error, _} -> "default"
      end

    :erlang.phash2({node_id, uuid}, 0xFFFF_FFFF)
  end
end

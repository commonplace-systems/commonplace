defmodule Commonplace.Presence.Identity do
  @moduledoc """
  Cold identity — permanent actor records in __identities__.

  Unlike hot presence files (which are created on start and deleted on
  shutdown), cold identities persist across restarts. They live in an
  `__identities__` system directory in the root schema.
  """

  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Presence
  alias Commonplace.SiblingMerger

  @identities_dir "__identities__"

  @doc """
  Collapse imported sibling commits on an identity doc into `:latest`
  (CX-tdkq.1 / R1).

  Identity docs are shared multi-writer documents: a concurrent write
  from another node arrives via `import_commit`, which deliberately does
  not advance `:latest` — leaving it a sibling that `read/2`'s
  latest-commit reconstruction can't see. Reads and writes below call
  this first so the registry converges instead of silently dropping the
  remote write.

  `CommitStoreClient` is a stateless routing module, not a GenServer, so
  it is normalized to the local `CommitStore` for the merger's direct
  calls (same single-node MVP assumption as `Gold.Chain`).
  """
  def converge(uuid, store \\ CommitStoreClient) do
    SiblingMerger.maybe_merge_siblings(normalize_store(store), uuid)
  end

  defp normalize_store(CommitStoreClient), do: CommitStore
  defp normalize_store(other), do: other

  # Metadata for identity-doc writes (CX-tdkq.1 / R1).
  #
  # SiblingMerger's underlying merge resolves the common ancestor at
  # snapshot-chain granularity (SnapshotAncestry walks
  # metadata.snapshot_parent back to a trust root), so legacy `%{}`
  # commits — whose namespace is nil — can never be converged. Writing
  # `%{kind: :regular}` lets CommitStore auto-stamp `snapshot_parent`
  # (genesis for a fresh doc), making the doc umbrella-shaped and
  # mergeable.
  #
  # The umbrella shape is applied only when the stamp can succeed: a
  # fresh doc (genesis parent) or a doc whose head already carries a
  # namespace. Chaining a `:regular` commit onto a LEGACY head would
  # produce kind-without-snapshot_parent, which peers' namespace
  # validators reject on import — so legacy docs keep writing legacy
  # commits (and simply don't converge, as before).
  defp write_metadata(uuid, store) do
    case CommitStoreClient.latest_commit(store, uuid) do
      :none ->
        %{kind: :regular}

      {:ok, head} ->
        if Commonplace.Store.Namespace.current_namespace(head) do
          %{kind: :regular}
        else
          %{}
        end
    end
  end

  # CX-88mw(ii): the commit opts derived from a caller's `opts`. Only
  # `:signing_context` is forwarded — when absent, every write keeps the
  # legacy default-signing behavior bit-for-bit.
  defp commit_opts(opts) do
    case Keyword.get(opts, :signing_context) do
      nil -> []
      ctx -> [signing_context: ctx]
    end
  end

  @doc """
  Ensure the __identities__ system directory exists in the root schema.

  `opts[:signing_context]` (CX-88mw ii) signs the directory-creation and
  root-schema commits when the dir is minted here; no-op when it exists.
  """
  def ensure_identities_dir(root_uuid, store \\ CommitStoreClient, opts \\ []) do
    root_doc = load_schema(root_uuid, store)

    case Schema.get_entry(root_doc, @identities_dir) do
      {:ok, entry} ->
        {:ok, entry.node_id}

      :error ->
        # Create the identities directory schema doc
        dir_uuid = UUID.uuid4()
        dir_doc = Schema.new_schema()
        update = Yelixer.Encoding.encode_update(dir_doc)
        CommitStoreClient.create_commit(store, dir_uuid, update, nil, %{}, commit_opts(opts))

        # Add to root schema
        root_doc = load_schema(root_uuid, store)
        root_doc = Schema.add_directory(root_doc, @identities_dir, dir_uuid)
        update = Yelixer.Encoding.encode_update(root_doc)
        CommitStoreClient.create_chained_commit(store, root_uuid, update, %{}, commit_opts(opts))

        {:ok, dir_uuid}
    end
  end

  @doc """
  Register a cold identity. Creates if new, updates last_seen if existing.

  `opts[:signing_context]` (CX-88mw ii / D9): the registration commits —
  identity doc, __identities__ schema entry, and any schema commits made
  by `ensure_identities_dir` — are signed with the supplied
  `Commonplace.Crypto.SigningContext`. Without it, the legacy behavior
  (global-SecretStore fallback / unsigned) is unchanged.
  """
  def register(name, type, root_uuid, store \\ CommitStoreClient, opts \\ []) do
    {:ok, id_dir_uuid} = ensure_identities_dir(root_uuid, store, opts)
    fname = Presence.filename(name, type)

    id_doc = load_schema(id_dir_uuid, store)

    case Schema.get_entry(id_doc, fname) do
      {:ok, entry} ->
        # Existing identity — update last_seen
        touch_last_seen(entry.node_id, store, opts)
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

        CommitStoreClient.create_commit(
          store,
          uuid,
          update,
          nil,
          write_metadata(uuid, store),
          commit_opts(opts)
        )

        # Add to identities schema
        id_doc = load_schema(id_dir_uuid, store)
        id_doc = Schema.add_file(id_doc, fname, uuid)
        update = Yelixer.Encoding.encode_update(id_doc)

        CommitStoreClient.create_chained_commit(
          store,
          id_dir_uuid,
          update,
          %{},
          commit_opts(opts)
        )

        {:ok, uuid}
    end
  end

  @doc """
  Register an agent as a first-class signing principal (CX-88mw ii):
  a `:bot` cold identity + a freshly-minted (idempotent) per-agent
  Ed25519 keypair in the node-local SecretStore + the pubkey appended to
  the identity doc. Returns `{:ok, identity_uuid, public_key}`.

  ## Who signs the registration (decision D9)

  The CREATOR signs: pass the minting principal's `SigningContext` as
  `opts[:signing_context]` — the same principal that subsequently
  `cap delegate`s the agent its scoped capability cert, so
  accountability chains end-to-end. In headless contexts (no human in
  the loop) pass the node's context
  (`Commonplace.Crypto.NodeIdentity.signing_context/0`) — node-signing
  is the sanctioned fallback.

  The pubkey copy in the identity doc is convenience only (D6):
  authority comes from the capability cert delegated to this key, never
  from the (peer-writable) identity doc.

  `opts[:secret_store]` overrides the SecretStore instance holding the
  agent's key custody (defaults to the global one).
  """
  def register_agent(name, root_uuid, store \\ CommitStoreClient, opts \\ []) do
    secret_store = Keyword.get(opts, :secret_store, Commonplace.Store.SecretStore)

    with {:ok, uuid} <- register(name, :bot, root_uuid, store, opts),
         {:ok, pub} <- Commonplace.Crypto.AgentKeys.ensure(uuid, secret_store),
         :ok <- add_public_key(uuid, Base.encode64(pub), store, opts) do
      {:ok, uuid, pub}
    end
  end

  @doc """
  Register a player as a first-class signing principal (CX-qat5.2 §2.1):
  a `:usr` cold identity + a freshly-minted (idempotent) per-player
  Ed25519 keypair in the node-local SecretStore + the pubkey appended to
  the identity doc. Returns `{:ok, identity_uuid, public_key}`.

  Mirrors `register_agent/4` exactly (same custody + signing shape,
  same D6/D9 decisions) with one change: `:usr` kind instead of `:bot`,
  because a browser player is a human principal, not an agent. See
  `register_agent/4`'s doc for the D9 (creator-signs) and D6
  (doc-copy-is-convenience, capability-cert-is-authority) rationale —
  it applies identically here. `Commonplace.Invites.mint/4` is this
  function's caller: minting an invite registers the player, then
  mints the one-time login token separately.
  """
  def register_player(name, root_uuid, store \\ CommitStoreClient, opts \\ []) do
    secret_store = Keyword.get(opts, :secret_store, Commonplace.Store.SecretStore)

    with {:ok, uuid} <- register(name, :usr, root_uuid, store, opts),
         {:ok, pub} <- Commonplace.Crypto.AgentKeys.ensure(uuid, secret_store),
         :ok <- add_public_key(uuid, Base.encode64(pub), store, opts) do
      {:ok, uuid, pub}
    end
  end

  @doc "Read a cold identity document (converging any imported siblings first)."
  def read(uuid, store \\ CommitStoreClient) do
    converge(uuid, store)

    case reconstruct(uuid, store) do
      {:ok, doc} -> ContentType.get_content(doc)
      :none -> nil
    end
  end

  # Full-chain reconstruction with the workspace's stable client_id
  # reapplied so subsequent writes reuse the same Yjs client (the
  # CX-3ty/CX-6g6 state-vector discipline).
  #
  # Latest-commit-only reconstruction is no longer sufficient here: a
  # SiblingMerger merge commit is a DELTA on top of the local head (R's
  # translated edits), so reading just the head would drop everything
  # the pre-merge chain carried.
  defp reconstruct(uuid, store) do
    case Commonplace.Tree.DocBuilder.reconstruct_doc(store, uuid) do
      {:ok, doc} -> {:ok, %{doc | client_id: stable_client_id(uuid)}}
      :none -> :none
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

  @doc """
  Update last_seen timestamp on a cold identity.
  `opts[:signing_context]` signs the commit (CX-88mw ii).
  """
  def touch_last_seen(uuid, store \\ CommitStoreClient, opts \\ []) do
    converge(uuid, store)

    case reconstruct(uuid, store) do
      {:ok, doc} ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()
        doc = ContentType.set_key(doc, "last_seen", now)
        update = Yelixer.Encoding.encode_update(doc)

        CommitStoreClient.create_chained_commit(
          store,
          uuid,
          update,
          write_metadata(uuid, store),
          commit_opts(opts)
        )

      :none ->
        :ok
    end
  end

  @doc """
  Add a public key to an identity document.

  Convenience copy only (D6): authority comes from a capability cert
  delegated to the key, never from this (peer-writable) doc.
  `opts[:signing_context]` signs the commit (CX-88mw ii).
  """
  def add_public_key(identity_uuid, public_key_b64, store \\ CommitStoreClient, opts \\ []) do
    converge(identity_uuid, store)

    case reconstruct(identity_uuid, store) do
      {:ok, doc} ->
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

          CommitStoreClient.create_chained_commit(
            store,
            identity_uuid,
            update,
            write_metadata(identity_uuid, store),
            commit_opts(opts)
          )
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

defmodule Commonplace.MUD.SessionViewLink do
  @moduledoc """
  CX-i9j3 (UI Inc-1 increment 4b): tree-LINK a freshly-minted
  `Commonplace.MUD.SessionView` view-doc into the schema tree so it is
  REACHABLE-FROM-ROOT (walkable via `Commonplace.Tree.Walk.reachable_uuids/2`
  starting from the workspace/mud root), instead of being reachable ONLY
  via the in-memory `Commonplace.MUD.SessionViewRegistry` pointer.

  ## The problem this fixes

  `SessionView.new/3` mints a floating doc — a fresh uuid + genesis
  commit that is not linked into the schema tree anywhere. Without a
  tree link, that view-doc is GC-orphanable and — more immediately —
  vanishes from the durability story on serve restart (the registry
  itself is in-memory-only; see `SessionViewRegistry`'s moduledoc). This
  module makes "the committed transcript is durable" actually true by
  giving every minted view-doc a real parent in the tree.

  ## Placement

  `link/3` provisions (idempotently, node-signed) a `sessions/`
  directory under the player's home room (`home_room_uuid`, as returned
  by `Commonplace.MUD.Citizenship.ensure/5`), then adds the view-doc as
  a FILE entry named after its own uuid:

      players/<name>/sessions/<view_uuid>   (file entry -> view_uuid)

  `Commonplace.Tree.Walk.reachable_uuids/2` treats non-dir entries as
  leaves — it adds the entry's `node_id` to the visited set without
  trying to load it as a schema doc — so linking the view-doc directly
  as a file entry under `sessions/` is sufficient for reachability; no
  extra directory level is needed.

  ## Node-signed, mirrors `Commonplace.MUD.Citizenship`

  Every commit here is node-signed via
  `Commonplace.Crypto.NodeIdentity.signing_context/0` — EXACTLY the
  same `[store: store, signing_context: node_ctx]` write_opts
  convention `Citizenship` uses for its own node-signed home
  provisioning (`ensure_players_dir/2`, `ensure_player_home/4`) — so
  these writes land under `local_write_gate: :enforce` without needing
  any player-held capability. View-doc writes are infrastructure (the
  session's own transcript, not player-authored content), same
  rationale `SessionView`'s own moduledoc gives for signing its append
  commits with the node identity.

  ## Idempotent both ways

  `ensure_sessions_dir/2` only creates `sessions/` once per home room
  (get-entry-before-create, like `Citizenship.ensure_players_dir/2`).
  `ensure_session_entry/3` only links a given view_uuid once — a
  reconnect that reloads (rather than mints) a view never calls this
  module at all (see `MudLive`'s `mint_and_link/3` — `link/3` is only
  invoked from the mint-fresh branches of `load_or_new_view/3`), but
  even a repeat call with the same view_uuid is a no-op rather than a
  duplicate entry/commit.

  Returns `:ok` or `{:error, reason}`. Callers should treat a failure as
  non-fatal — a floating (unlinked) view-doc is still a working session,
  just not tree-durable yet; see `MudLive`'s `maybe_link_view/3` for the
  catch/log/continue wrapper.
  """

  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.MUD.Schemas
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  @sessions_dir "sessions"

  @doc """
  Idempotently link `view_uuid` under `players/<name>/sessions/<view_uuid>`
  (a file entry) beneath `home_room_uuid`. Node-signed. Returns `:ok` or
  `{:error, reason}`.
  """
  @spec link(String.t(), String.t(), module()) :: :ok | {:error, term()}
  def link(home_room_uuid, view_uuid, store)
      when is_binary(home_room_uuid) and is_binary(view_uuid) do
    with {:ok, node_ctx} <- NodeIdentity.signing_context() do
      write_opts = [store: store, signing_context: node_ctx]

      with {:ok, sessions_dir_uuid} <- ensure_sessions_dir(home_room_uuid, write_opts),
           :ok <- ensure_session_entry(sessions_dir_uuid, view_uuid, write_opts) do
        :ok
      end
    end
  end

  # ---- private ----

  defp ensure_sessions_dir(home_room_uuid, write_opts) do
    store = Keyword.fetch!(write_opts, :store)

    case Schemas.load_dir_schema(home_room_uuid, store) do
      {:ok, home_schema} ->
        case Schema.get_entry(home_schema, @sessions_dir) do
          {:ok, entry} ->
            {:ok, entry.node_id}

          :error ->
            with {:ok, new_uuid} <- Schemas.create_dir_with_meta(nil, nil, store, write_opts),
                 :ok <- add_dir_entry(home_room_uuid, @sessions_dir, new_uuid, write_opts) do
              {:ok, new_uuid}
            end
        end

      {:error, reason} ->
        {:error, {:no_home_schema, reason}}
    end
  end

  defp ensure_session_entry(sessions_dir_uuid, view_uuid, write_opts) do
    store = Keyword.fetch!(write_opts, :store)

    case Schemas.load_dir_schema(sessions_dir_uuid, store) do
      {:ok, sessions_schema} ->
        case Schema.get_entry(sessions_schema, view_uuid) do
          {:ok, _entry} -> :ok
          :error -> add_file_entry(sessions_dir_uuid, view_uuid, view_uuid, write_opts)
        end

      {:error, reason} ->
        {:error, {:no_sessions_schema, reason}}
    end
  end

  defp add_dir_entry(parent_uuid, name, child_uuid, write_opts),
    do: add_entry(parent_uuid, write_opts, &Schema.add_directory(&1, name, child_uuid))

  defp add_file_entry(parent_uuid, name, child_uuid, write_opts),
    do: add_entry(parent_uuid, write_opts, &Schema.add_file(&1, name, child_uuid))

  defp add_entry(parent_uuid, write_opts, mutate) do
    store = Keyword.fetch!(write_opts, :store)
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    update = Encoding.encode_update(mutate.(schema))
    signing_context = Keyword.get(write_opts, :signing_context)
    commit_opts = if signing_context, do: [signing_context: signing_context], else: []

    case CommitStoreClient.create_chained_commit(store, parent_uuid, update, %{}, commit_opts) do
      {:error, _} = err -> err
      _commit -> :ok
    end
  end
end

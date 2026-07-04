defmodule Commonplace.MUD.Move do
  @moduledoc """
  Cross-doc moves guarded by green tokens — the green channel for real.

  Replaces the retired `MoveServer` (move #4, CX-tdkq.7), whose own
  moduledoc called it a "v0 stand-in for the green channel": instead of
  serializing every move through one `{:global, …}`-registered process
  (the split-brain hazard — `:global` name-conflict resolution on node
  join could kill or orphan the singleton, and a netsplit allowed two),
  each move takes exclusive green tokens on the two directory schemas it
  mutates and runs the same check-then-write sequence under them. No
  singleton, no election; disjoint moves parallelize.

  ## Locking discipline

    * Token names are the source/dest dir-schema UUIDs, acquired in
      CANONICAL (sorted) order. Deny-on-contention cannot deadlock, but
      two overlapping moves each holding one token could livelock
      retrying; canonical order makes one of them win both.
    * On deny: release whatever was acquired, retry bounded
      (`retries:` × `retry_ms:`), then `{:error, :busy}`.
    * Tokens are released on EVERY exit path — success, `:gone`,
      `:collision`, crash — via `try/after`. The short token TTL
      (`ttl:`, default #{5_000}ms) is only the crash net for a mover
      whose whole BEAM dies mid-move.
    * No bursar reachable → `{:error, :bursar_unavailable}`: fail
      closed, never move unlocked (see `Commonplace.Green.BursarClient`).

  Write ordering within the move is unchanged from v0: dest-add FIRST,
  then source-remove. A crash between the two writes leaves the entry in
  both rooms (recoverable: reaper / manual scrub) rather than nowhere
  (silently lost). See spec §2.4.
  """

  alias Commonplace.Green.{Bursar, BursarClient}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Commonplace.MUD.Schemas, as: MudSchemas
  alias Yelixer.Encoding

  @move_ttl_ms 5_000
  @retries 20
  @retry_ms 50

  @doc """
  Move `thing_uuid` (entry named `name`) from `source_dir_uuid` to
  `dest_dir_uuid` under green tokens.

  Options: `:store` (default `CommitStoreClient`), `:bursar` (default
  the locally/remotely routed `Bursar` — see `BursarClient`), `:ttl`,
  `:retries`, `:retry_ms`.

  Returns `:ok`, `{:error, :gone}` if the entry isn't where we think it
  is, `{:error, :collision}` on a dest name clash, `{:error, :busy}` if
  the dir tokens stayed contended through the retry budget, or
  `{:error, :bursar_unavailable}` when no lock authority is reachable.
  """
  def move(thing_uuid, name, source_dir_uuid, dest_dir_uuid, opts \\ [])

  def move(_thing_uuid, _name, source, dest, _opts) when source == dest, do: :ok

  def move(thing_uuid, name, source_dir_uuid, dest_dir_uuid, opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    bursar = Keyword.get(opts, :bursar, Bursar)
    ttl = Keyword.get(opts, :ttl, @move_ttl_ms)
    retries = Keyword.get(opts, :retries, @retries)
    retry_ms = Keyword.get(opts, :retry_ms, @retry_ms)

    holder = default_holder()
    paths = Enum.sort([source_dir_uuid, dest_dir_uuid])

    case acquire_all(paths, holder, bursar, ttl, retries, retry_ms) do
      :ok ->
        try do
          do_move(thing_uuid, name, source_dir_uuid, dest_dir_uuid, store)
        after
          release_all(paths, holder, bursar)
        end

      {:error, _} = err ->
        err
    end
  end

  # CX-tdkq.32: the default holder is a NAMED principal, never a free
  # string — prefixed with the node identity so the Bursar's
  # `authenticated_as` binding ties this ephemeral per-move holder to
  # an accountable signer. The pid/ref suffix keeps it unique per
  # concurrent move (multiple moves must not collide on one holder
  # string). Falls back to the old unprefixed form only if the node
  # identity is unavailable, so a move still fails closed rather than
  # crashing.
  defp default_holder do
    case Commonplace.Crypto.NodeIdentity.identity() do
      {:ok, node_identity} -> "#{node_identity}/move-#{inspect(self())}@#{node()}"
      {:error, _} -> "move:#{inspect(self())}@#{node()}"
    end
  end

  # --- Token discipline ---

  defp acquire_all(paths, holder, bursar, ttl, retries, retry_ms) do
    case try_acquire(paths, holder, bursar, ttl, []) do
      :ok ->
        :ok

      {:denied, got} ->
        release_all(got, holder, bursar)

        if retries > 0 do
          Process.sleep(retry_ms)
          acquire_all(paths, holder, bursar, ttl, retries - 1, retry_ms)
        else
          {:error, :busy}
        end

      {:error, reason, got} ->
        release_all(got, holder, bursar)
        {:error, reason}
    end
  end

  defp try_acquire([], _holder, _bursar, _ttl, _got), do: :ok

  defp try_acquire([path | rest], holder, bursar, ttl, got) do
    case BursarClient.acquire(bursar, path, holder, ttl: ttl, authenticated_as: holder) do
      {:ok, _} -> try_acquire(rest, holder, bursar, ttl, [path | got])
      {:denied, _} -> {:denied, got}
      {:error, reason} -> {:error, reason, got}
    end
  end

  defp release_all(paths, holder, bursar) do
    Enum.each(paths, fn path ->
      BursarClient.release(bursar, path, holder, authenticated_as: holder)
    end)
  end

  # --- The move itself (unchanged from MoveServer v0) ---

  defp do_move(thing_uuid, name, source_dir_uuid, dest_dir_uuid, store) do
    with {:ok, source_schema} <- MudSchemas.load_dir_schema(source_dir_uuid, store),
         {:ok, %Schema.Entry{} = entry} <- check_still_there(source_schema, name, thing_uuid),
         {:ok, dest_schema} <- MudSchemas.load_dir_schema(dest_dir_uuid, store),
         :ok <- check_no_collision(dest_schema, name) do
      :ok = add_to_dest(dest_dir_uuid, name, entry, store)
      :ok = remove_from_source(source_dir_uuid, name, store)
      :ok
    else
      {:error, _} = err -> err
      :error -> {:error, :gone}
      :none -> {:error, :gone}
    end
  end

  defp check_still_there(schema, name, thing_uuid) do
    case Schema.get_entry(schema, name) do
      {:ok, %Schema.Entry{node_id: ^thing_uuid} = entry} -> {:ok, entry}
      {:ok, %Schema.Entry{}} -> {:error, :gone}
      :error -> {:error, :gone}
    end
  end

  defp check_no_collision(schema, name) do
    case Schema.get_entry(schema, name) do
      :error -> :ok
      {:ok, _} -> {:error, :collision}
    end
  end

  defp add_to_dest(dest_dir_uuid, name, %Schema.Entry{type: type, node_id: node_id}, store) do
    {:ok, doc} = MudSchemas.load_dir_schema(dest_dir_uuid, store)

    doc =
      case type do
        :dir -> Schema.add_directory(doc, name, node_id)
        _ -> Schema.add_file(doc, name, node_id)
      end

    update = Encoding.encode_update(doc)
    CommitStoreClient.create_chained_commit(store, dest_dir_uuid, update)
    :ok
  end

  defp remove_from_source(source_dir_uuid, name, store) do
    {:ok, doc} = MudSchemas.load_dir_schema(source_dir_uuid, store)
    doc = Schema.remove_entry(doc, name)
    update = Encoding.encode_update(doc)
    CommitStoreClient.create_chained_commit(store, source_dir_uuid, update)
    :ok
  end
end

defmodule Commonplace.MUD.Mint do
  @moduledoc """
  CX-cj3t (items epic phase 2) — the MINT/CONSUME chokepoint: create an
  item that never existed (MINE, later SMITH), and destroy one a player
  holds (later SMITH).

  ## The one new primitive: mint-to-first-holder = `Bursar.acquire`

  Every existing item op (TAKE/DROP/GIVE) is a *transfer* between
  holders. MINE/SMITH create an item that has no prior holder, so there
  is no `from`. The bursar already has the exact primitive:
  `Bursar.acquire(uuid, holder, authenticated_as: holder, ttl: nil)` on
  a never-held path grants the token to `holder` as the FIRST holder —
  no transfer needed. `mint_item/4` does this: it creates a fresh object
  dir (node-signed — the TYPE is source-authored anti-forgery, never
  player-signed) under the destination inventory, then acquires the
  possession token directly to the owner.

  `consume_item/3` is the inverse: release the holder's own token (so it
  can only ever consume a token the caller itself holds) and unlink the
  item doc from its inventory (reachability-is-liveness = destruction).

  ## AVAILABILITY-BOUND (design §3.1 — load-bearing)

  This module is reachable ONLY from the mine/smith verb bodies
  (`Commonplace.MUD.Verbs.do_mine`, and later `do_smith`). It is
  deliberately NOT wired onto `Commonplace.MUD.World` or
  `Commonplace.MUD.World.Facade` as a public op, and NOT added to the
  safe-verb facade allowlist
  (`Commonplace.MUD.SafeVerb.Allowlist.@facade_allowed`) — a
  player-authored verb body can never reach "mint me a fresh token for
  an item I invented" by calling through the facade. Mint AUTHORITY is
  the node-signed vein/recipe grant (definer's-rights), never the
  invoking player.

  ## Vein extraction (`extract_from_vein/4`) — the MINE mechanic

  `extract_from_vein/4` is the lazy-regen decrement + mint used by
  `do_mine`. It runs under a **Bursar exclusive lock keyed on the
  vein's own uuid** (mirrors `Commonplace.MUD.Move`'s move-lock
  discipline) so the read-compute-write critical section
  (`yield_remaining`/`last_regen_at` are read, then written back as a
  single node-signed commit) is never split across two concurrent
  miners — without the lock, two readers could both observe the same
  `yield_remaining` and both mint off the "last" charge (M4). The lock
  is ephemeral (TTL crash-net, released in `after`), never persisted
  ownership.

  **STRUCTURAL GUARD (design §3.2 / attack M2).** The vein meta rewrite
  (`write_vein_meta/3`) is built via `%Schemas.Object{vein | ...}` —
  Elixir struct-update syntax that copies every OTHER field verbatim
  from the doc just loaded (`vein`) and only overrides
  `yield_remaining`/`last_regen_at`. There is no parameter path by which
  a caller can supply a different `yield_type`/`yield_max`/
  `regen_per_ms` — those three are never read from anywhere but the
  loaded node-signed doc. `yield_remaining` can only ever be assigned
  `current - 1` (one less than the just-computed, capped `current`), so
  it can only move down between successive mines (regen is the only way
  it moves up, and regen is itself capped at `yield_max`, §1c/§3.2/§3.4).
  """

  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Green.Bursar
  alias Commonplace.MUD.{Schemas, SignedWrite}
  alias Commonplace.MUD.Schemas.Object
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  @vein_lock_ttl_ms 5_000
  @vein_lock_retries 20
  @vein_lock_retry_ms 50

  # ---- MINT ----

  @doc """
  Mint a fresh item from `template` (a name/aliases/description map,
  string- or atom-keyed — e.g. a vein's `yield_type`) into
  `dest_inventory_uuid`, granting the possession token to
  `owner_identity` as FIRST holder.

  Returns `{:ok, new_uuid}` or `{:error, reason}`.

  `opts`: `:store` (default `CommitStoreClient`), `:bursar` (default
  `Bursar`), `:uuid` — an explicit uuid for the minted item (SMITH will
  pass one pre-generated so it can lock it before minting; MINE lets it
  default to a fresh `UUID.uuid4()`).

  The new object dir + its `__obj.json` are created and linked
  NODE-SIGNED (`NodeIdentity.signing_context/0`) — the object TYPE is
  source-authored anti-forgery, never player-signed, regardless of who
  eventually holds the item. On any failure after the dir/link land but
  before the token is acquired, the link is rolled back (unlinked) so no
  ownerless item is left reachable.
  """
  @spec mint_item(map(), String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def mint_item(template, dest_inventory_uuid, owner_identity, opts \\ [])
      when is_binary(dest_inventory_uuid) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    bursar = Keyword.get(opts, :bursar, Bursar)
    uuid = Keyword.get(opts, :uuid) || UUID.uuid4()

    case do_mint(template, uuid, dest_inventory_uuid, owner_identity, store, bursar) do
      {:ok, _} = ok -> ok
      {:error, _} = err -> err
    end
  end

  defp do_mint(template, uuid, dest_inventory_uuid, owner_identity, store, bursar) do
    with {:ok, node_ctx} <- NodeIdentity.signing_context() do
      node_opts = [store: store, signing_context: node_ctx, cert_cids: []]

      object = %Object{
        name: tf(template, :name, "object"),
        aliases: tf(template, :aliases, []),
        description: tf(template, :description, ""),
        fixed: false
      }

      entry_name_val = instance_entry_name(object.name, uuid)

      with {:ok, ^uuid} <- create_dir_with_uuid(uuid, Schemas.object_filename(), Schemas.encode_object(object), node_opts),
           :ok <- link_into_parent(dest_inventory_uuid, entry_name_val, uuid, node_opts),
           {:ok, _} <- Bursar.acquire(bursar, uuid, owner_identity, authenticated_as: owner_identity, ttl: nil) do
        {:ok, uuid}
      else
        {:denied, _} ->
          unlink_from_parent(dest_inventory_uuid, entry_name_val, node_opts)
          {:error, :mint_token_unavailable}

        {:error, _} = err ->
          unlink_from_parent(dest_inventory_uuid, entry_name_val, node_opts)
          err
      end
    end
  end

  @doc """
  Consume (destroy) `item_uuid` held by `holder_identity`:
  `Bursar.release` (holder-only — structurally can only consume a token
  the CALLER holds) **+** unlink the item doc from its inventory
  (`opts[:inventory_uuid]` — reachability-is-liveness, unlinking IS
  destruction). Returns `:ok | {:error, reason}`.

  If `opts[:inventory_uuid]` is omitted, only the token is released (no
  unlink attempted) — callers that already know the item is unlinked
  (e.g. a rollback after a failed vein-write) can skip the lookup.
  """
  @spec consume_item(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def consume_item(item_uuid, holder_identity, opts \\ []) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    bursar = Keyword.get(opts, :bursar, Bursar)
    inventory_uuid = Keyword.get(opts, :inventory_uuid)

    case Bursar.release(bursar, item_uuid, holder_identity, authenticated_as: holder_identity) do
      :ok -> unlink_if_present(item_uuid, inventory_uuid, store)
      {:error, _} = err -> err
    end
  end

  defp unlink_if_present(_item_uuid, nil, _store), do: :ok

  defp unlink_if_present(item_uuid, inventory_uuid, store) do
    case entry_name(inventory_uuid, item_uuid, store) do
      {:ok, name} ->
        case NodeIdentity.signing_context() do
          {:ok, node_ctx} -> unlink_from_parent(inventory_uuid, name, store: store, signing_context: node_ctx, cert_cids: [])
          {:error, _} = err -> err
        end

      :error ->
        :ok
    end
  end

  # ---- MINE: vein extraction ----

  @doc """
  Extract one unit from the vein at `vein_uuid` into
  `dest_inventory_uuid`, on behalf of `miner_identity`. The MINE
  mechanic — see moduledoc.

  Returns `{:ok, new_item_uuid, item_name}`, `{:error, :depleted}`
  (graceful refuse — vein has nothing to give right now, no mint, no
  write), `{:error, :not_a_vein}`, `{:error, :bad_arg}` (no/blank
  miner identity), `{:error, :busy}` (lost the vein lock through the
  retry budget), or whatever `mint_item/4`/the vein rewrite surfaces.

  `opts`: `:store`, `:bursar`, `:ttl`/`:retries`/`:retry_ms` (the vein
  lock's own tuning — same names/defaults as `Commonplace.MUD.Move`'s
  move-lock).
  """
  @spec extract_from_vein(String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def extract_from_vein(vein_uuid, dest_inventory_uuid, miner_identity, opts \\ [])

  def extract_from_vein(_vein_uuid, _dest_inventory_uuid, miner_identity, _opts)
      when not is_binary(miner_identity) or miner_identity == "" do
    {:error, :bad_arg}
  end

  def extract_from_vein(vein_uuid, dest_inventory_uuid, miner_identity, opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    bursar = Keyword.get(opts, :bursar, Bursar)
    ttl = Keyword.get(opts, :ttl, @vein_lock_ttl_ms)
    retries = Keyword.get(opts, :retries, @vein_lock_retries)
    retry_ms = Keyword.get(opts, :retry_ms, @vein_lock_retry_ms)

    with {:ok, node_identity} <- NodeIdentity.identity() do
      holder = "#{node_identity}/mine-#{inspect(self())}@#{node()}"
      lock_path = "vein-lock:#{vein_uuid}"

      case acquire_lock(lock_path, holder, bursar, ttl, retries, retry_ms) do
        :ok ->
          try do
            do_extract(vein_uuid, dest_inventory_uuid, miner_identity, store, bursar, opts)
          after
            Bursar.release(bursar, lock_path, holder, authenticated_as: holder)
          end

        {:error, _} = err ->
          err
      end
    end
  end

  defp acquire_lock(path, holder, bursar, ttl, retries, retry_ms) do
    case Bursar.acquire(bursar, path, holder, ttl: ttl, authenticated_as: holder) do
      {:ok, _} ->
        :ok

      {:denied, _} ->
        if retries > 0 do
          Process.sleep(retry_ms)
          acquire_lock(path, holder, bursar, ttl, retries - 1, retry_ms)
        else
          {:error, :busy}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_extract(vein_uuid, dest_inventory_uuid, miner_identity, store, bursar, opts) do
    case Schemas.load_object(vein_uuid, store) do
      {:ok, %Object{kind: "vein"} = vein} ->
        now = clock()
        regened = regen_amount(vein, now)
        yield_max = vein.yield_max || 0
        current = min(yield_max, (vein.yield_remaining || 0) + regened)

        if current < 1 do
          {:error, :depleted}
        else
          run_extraction(vein_uuid, vein, current, now, dest_inventory_uuid, miner_identity, store, bursar, opts)
        end

      {:ok, %Object{}} ->
        {:error, :not_a_vein}

      {:error, _} ->
        {:error, :not_a_vein}
    end
  end

  defp regen_amount(%Object{regen_per_ms: nil}, _now), do: 0
  defp regen_amount(%Object{regen_per_ms: 0}, _now), do: 0

  defp regen_amount(%Object{regen_per_ms: rate, last_regen_at: last}, now) when is_number(rate) do
    anchor = last || now
    floor((now - anchor) * rate)
  end

  defp clock, do: System.system_time(:millisecond)

  # STRUCTURAL GUARD (design §3.2/M2) — mint FIRST, then rewrite the vein
  # meta via `%Object{vein | ...}`: every field except yield_remaining/
  # last_regen_at is copied verbatim from the doc `do_extract` just
  # loaded. No parameter here can smuggle a different protected value in.
  defp run_extraction(vein_uuid, vein, current, now, dest_inventory_uuid, miner_identity, store, bursar, opts) do
    mint_opts = Keyword.merge(opts, store: store, bursar: bursar)

    case mint_item(vein.yield_type, dest_inventory_uuid, miner_identity, mint_opts) do
      {:ok, item_uuid} ->
        updated = %Object{vein | yield_remaining: current - 1, last_regen_at: now}

        case write_vein_meta(vein_uuid, updated, store) do
          :ok ->
            {:ok, item_uuid, tf(vein.yield_type, :name, "ore")}

          {:error, reason} ->
            # Vein write failed AFTER the mint landed — roll back the mint
            # so the world stays consistent (no ownerless/ungranted item).
            consume_item(item_uuid, miner_identity, inventory_uuid: dest_inventory_uuid, store: store, bursar: bursar)
            {:error, reason}
        end

      {:error, _} = err ->
        err
    end
  end

  defp write_vein_meta(vein_uuid, %Object{} = updated, store) do
    with {:ok, node_ctx} <- NodeIdentity.signing_context(),
         {:ok, schema} <- Schemas.load_dir_schema(vein_uuid, store),
         {:ok, entry} <- Schema.get_entry(schema, Schemas.object_filename()) do
      json = Schemas.encode_object(updated)
      Schemas.write_meta_doc(entry.node_id, json, store, signing_context: node_ctx, cert_cids: [])
    else
      :error -> {:error, :no_meta_entry}
      {:error, _} = err -> err
    end
  end

  # ---- shared low-level tree helpers (node-signed create+link+unlink) ----

  # Mirrors `Commonplace.MUD.World.Facade`'s private `create_object_in`
  # create+link, but with an EXPLICIT uuid (so a caller — SMITH — can
  # lock it before it exists) and the NODE signing context, never the
  # invoker's. `Schemas.create_dir_with_meta/4` always mints its own
  # random uuid, so this inlines its logic against `uuid` instead.
  defp create_dir_with_uuid(uuid, meta_filename, json, opts) do
    store = Keyword.fetch!(opts, :store)

    case Schemas.create_meta_doc(json, store, opts) do
      {:error, _} = err ->
        err

      {:ok, meta_uuid} ->
        dir_doc = Schema.new_schema() |> Schema.add_file(meta_filename, meta_uuid)
        update = Encoding.encode_update(dir_doc)
        {metadata, commit_opts} = SignedWrite.opts_for(uuid, Keyword.put(opts, :store, store))

        case CommitStoreClient.create_commit(store, uuid, update, nil, metadata, commit_opts) do
          {:error, _} = err -> err
          _commit -> {:ok, uuid}
        end
    end
  end

  defp link_into_parent(parent_uuid, entry_name_val, child_uuid, opts) do
    store = Keyword.fetch!(opts, :store)

    case Schemas.load_dir_schema(parent_uuid, store) do
      {:ok, schema} ->
        schema = Schema.add_directory(schema, entry_name_val, child_uuid)
        update = Encoding.encode_update(schema)
        {metadata, commit_opts} = SignedWrite.opts_for(parent_uuid, Keyword.put(opts, :store, store))

        case CommitStoreClient.create_chained_commit(store, parent_uuid, update, metadata, commit_opts) do
          {:error, _} = err -> err
          _commit -> :ok
        end

      {:error, _} = err ->
        err
    end
  end

  defp unlink_from_parent(parent_uuid, entry_name_val, opts) do
    store = Keyword.fetch!(opts, :store)

    case Schemas.load_dir_schema(parent_uuid, store) do
      {:ok, schema} ->
        schema = Schema.remove_entry(schema, entry_name_val)
        update = Encoding.encode_update(schema)
        {metadata, commit_opts} = SignedWrite.opts_for(parent_uuid, Keyword.put(opts, :store, store))
        CommitStoreClient.create_chained_commit(store, parent_uuid, update, metadata, commit_opts)
        :ok

      {:error, _} = err ->
        err
    end
  end

  defp entry_name(dir_uuid, node_uuid, store) do
    case Schemas.load_dir_schema(dir_uuid, store) do
      {:ok, schema} ->
        case Enum.find(Schema.list_entries(schema), &(&1.node_id == node_uuid)) do
          %Schema.Entry{name: name} -> {:ok, name}
          nil -> :error
        end

      _ ->
        :error
    end
  end

  # Mirrors `Commonplace.MUD.World.Facade`'s private `instance_entry_name`.
  defp instance_entry_name(name, uuid) do
    short = uuid |> String.replace("-", "") |> String.slice(0, 8)
    "#{name}-#{short}.obj"
  end

  # Template field accessor — accepts string- OR atom-keyed maps (a
  # vein's `yield_type` comes back string-keyed from JSON; a caller
  # building a template in Elixir may use atoms).
  defp tf(template, key, default) when is_map(template) do
    Map.get(template, to_string(key), Map.get(template, key, default))
  end

  defp tf(_template, _key, default), do: default
end

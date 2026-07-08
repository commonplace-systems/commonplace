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
  alias Commonplace.MUD.{Move, Schemas, SignedWrite}
  alias Commonplace.MUD.Schemas.{Object, Recipe}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  @vein_lock_ttl_ms 5_000
  @vein_lock_retries 20
  @vein_lock_retry_ms 50

  @recipes_dir "__recipes"

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

  # ---- SMITH: the mint-before-consume saga ----

  @doc """
  Craft `recipe_name` for `crafter_identity`: consume the recipe's
  declared inputs from `crafter_inventory_uuid` and mint its output there.

  The ATOMICITY spine (design §2c): the entire saga runs under ONE
  `Move.with_lock` over the crafter's inventory dir (the same lock point
  GIVE/DROP/TAKE take via `Move.move`, so no concurrent op can move an
  input out mid-craft — attack S4), held across validate → mint → consume
  as a single critical section (a crash mid-craft is released by the lock
  TTL, so it can't wedge the inventory). Inside the lock:

    1. VALIDATE (no mutation): every declared input is a matching item in
       the crafter's inventory whose possession token the crafter holds.
       Any shortfall → refuse, nothing touched.
    2. MINT the output FIRST (§0). A mint failure aborts with the inputs
       UNTOUCHED — "never consume if the craft fails" is structural, not
       runtime-checked (mint precedes consume).
    3. CONSUME each declared input (release token + unlink — §2b).
    4. COMPENSATE a mid-consume failure: tombstone the minted output +
       re-acquire/re-link the already-consumed inputs. The output is
       minted exactly once, so this can never duplicate it (§3.7 / S6).

  Only `Commonplace.MUD.Verbs.do_smith` calls this (availability-bound).
  Returns `{:ok, output_name}`, `{:error, :no_recipe}`,
  `{:error, {:missing_input, type}}`, `{:error, :bad_arg}`,
  `{:error, :busy}` (lost the inventory lock), or a mint/store error.
  """
  @spec smith(String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def smith(recipe_name, crafter_inventory_uuid, crafter_identity, opts \\ [])

  def smith(_recipe_name, _crafter_inventory_uuid, crafter_identity, _opts)
      when not is_binary(crafter_identity) or crafter_identity == "" do
    {:error, :bad_arg}
  end

  def smith(recipe_name, crafter_inventory_uuid, crafter_identity, opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    bursar = Keyword.get(opts, :bursar, Bursar)
    root = Keyword.get(opts, :root_uuid)

    with {:ok, recipe} <- resolve_recipe(recipe_name, root, store) do
      Move.with_lock(
        [crafter_inventory_uuid],
        fn -> do_smith_saga(recipe, crafter_inventory_uuid, crafter_identity, store, bursar) end,
        bursar: bursar
      )
    end
  end

  # Recipes are curated node-signed DOCs under `root/__recipes/` (§2a).
  # Resolve by matching the requested name against each recipe's OWN
  # `name` field (case-insensitive) — robust to entry-name formatting.
  defp resolve_recipe(_name, nil, _store), do: {:error, :no_recipe}

  defp resolve_recipe(name, root, store) do
    needle = String.downcase(String.trim(name))

    with {:ok, root_schema} <- Schemas.load_dir_schema(root, store),
         {:ok, entry} <- Schema.get_entry(root_schema, @recipes_dir),
         {:ok, recipes_schema} <- Schemas.load_dir_schema(entry.node_id, store) do
      recipes_schema
      |> Schema.list_entries()
      |> Enum.filter(&(&1.type == :dir))
      |> Enum.find_value({:error, :no_recipe}, fn e ->
        case Schemas.load_recipe(e.node_id, store) do
          {:ok, %Recipe{name: rname} = recipe} ->
            if String.downcase(String.trim(rname)) == needle, do: {:ok, recipe}, else: false

          _ ->
            false
        end
      end)
    else
      _ -> {:error, :no_recipe}
    end
  end

  defp do_smith_saga(recipe, crafter_inv, crafter_identity, store, bursar) do
    with {:ok, input_uuids} <- validate_inputs(recipe, crafter_inv, crafter_identity, store, bursar) do
      # MINT OUTPUT FIRST — a failure here leaves the inputs UNTOUCHED (S2).
      case mint_item(recipe.output, crafter_inv, crafter_identity, store: store, bursar: bursar) do
        {:ok, output_uuid} ->
          case consume_all(input_uuids, crafter_identity, crafter_inv, store, bursar, []) do
            :ok ->
              {:ok, template_name(recipe.output, "item")}

            {:error, reason, consumed} ->
              compensate(output_uuid, consumed, crafter_inv, crafter_identity, store, bursar)
              {:error, reason}
          end

        {:error, _} = err ->
          err
      end
    end
  end

  # VALIDATE (no mutation): resolve, for each declared input, `qty`
  # DISTINCT items in the crafter's inventory whose Object name == the
  # declared type AND whose possession token the crafter currently holds.
  # `consume ⊆ declared+visible inputs` (S3): only recipe-declared types
  # are ever collected; the saga never reaches a general inventory-remove.
  defp validate_inputs(recipe, crafter_inv, crafter_identity, store, bursar) do
    case Schemas.load_dir_schema(crafter_inv, store) do
      {:ok, schema} ->
        item_entries = schema |> Schema.list_entries() |> Enum.filter(&(&1.type == :dir))

        Enum.reduce_while(recipe.inputs, {:ok, []}, fn input, {:ok, allocated} ->
          type = Map.get(input, "type")
          qty = Map.get(input, "qty", 1)

          matches =
            held_matches(item_entries, type, crafter_identity, store, bursar, allocated)

          if length(matches) >= qty do
            {:cont, {:ok, allocated ++ Enum.take(matches, qty)}}
          else
            {:halt, {:error, {:missing_input, type}}}
          end
        end)

      {:error, _} = err ->
        err
    end
  end

  # Item uuids in `entries` whose Object name matches `type`, held by
  # `crafter`, excluding any already `allocated` to a prior input.
  defp held_matches(entries, type, crafter, store, bursar, allocated) do
    entries
    |> Enum.map(& &1.node_id)
    |> Enum.reject(&(&1 in allocated))
    |> Enum.filter(fn uuid ->
      matches_type?(uuid, type, store) and held_by?(uuid, crafter, bursar)
    end)
  end

  defp matches_type?(uuid, type, store) do
    case Schemas.load_object(uuid, store) do
      {:ok, %Object{name: name}} -> String.downcase(name) == String.downcase(to_string(type))
      _ -> false
    end
  end

  defp held_by?(uuid, crafter, bursar) do
    match?({:held, %{holder: ^crafter}}, Bursar.query(bursar, uuid))
  end

  defp consume_all([], _crafter, _inv, _store, _bursar, _consumed), do: :ok

  defp consume_all([uuid | rest], crafter, inv, store, bursar, consumed) do
    case consume_item(uuid, crafter, inventory_uuid: inv, store: store, bursar: bursar) do
      :ok -> consume_all(rest, crafter, inv, store, bursar, [uuid | consumed])
      {:error, reason} -> {:error, reason, consumed}
    end
  end

  # COMPENSATION (§2c / S6): output minted exactly once, so tombstoning it
  # can never leave a duplicate; re-acquire + re-link the inputs already
  # consumed before the failure. The inventory lock is still held, so
  # nobody raced these meanwhile.
  defp compensate(output_uuid, consumed, crafter_inv, crafter, store, bursar) do
    consume_item(output_uuid, crafter, inventory_uuid: crafter_inv, store: store, bursar: bursar)
    Enum.each(consumed, &restore_input(&1, crafter_inv, crafter, store, bursar))
    :ok
  end

  defp restore_input(uuid, crafter_inv, crafter, store, bursar) do
    Bursar.acquire(bursar, uuid, crafter, authenticated_as: crafter, ttl: nil)

    with {:ok, %Object{name: name}} <- Schemas.load_object(uuid, store),
         {:ok, node_ctx} <- NodeIdentity.signing_context() do
      link_into_parent(crafter_inv, instance_entry_name(name, uuid), uuid,
        store: store,
        signing_context: node_ctx,
        cert_cids: []
      )
    else
      _ -> :ok
    end
  end

  defp template_name(template, default), do: tf(template, :name, default)

  @doc """
  List the curated recipes under `root/__recipes/` (read-only) — backs
  the `recipes` verb so a player can inspect inputs BEFORE crafting
  (informed consent, §2c / attack S3). Returns `[%Recipe{}]`.
  """
  @spec list_recipes(String.t() | nil, GenServer.server()) :: [Recipe.t()]
  def list_recipes(nil, _store), do: []

  def list_recipes(root, store) do
    with {:ok, root_schema} <- Schemas.load_dir_schema(root, store),
         {:ok, entry} <- Schema.get_entry(root_schema, @recipes_dir),
         {:ok, recipes_schema} <- Schemas.load_dir_schema(entry.node_id, store) do
      recipes_schema
      |> Schema.list_entries()
      |> Enum.filter(&(&1.type == :dir))
      |> Enum.flat_map(fn e ->
        case Schemas.load_recipe(e.node_id, store) do
          {:ok, recipe} -> [recipe]
          _ -> []
        end
      end)
    else
      _ -> []
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

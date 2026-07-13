defmodule Commonplace.MUD.Take do
  @moduledoc """
  CX-ix9n — TAKE under enforce: push-not-pull, two-layer.

  A visiting player under `local_write_gate: :enforce` cannot `take` an
  item from a curated room via an invoker-signed `Move.move` — BOTH
  writes fail: the source-remove writes the curated room dir schema
  (node-owned, taker has no cert), and the dest-add writes the taker's
  node-provisioned inventory dir schema (also node-owned, and again
  outside the taker's cert scope: `{:presence,id}` + `{:docs,
  [home_room_meta]}` covers neither).

  So TAKE inverts the direction: the node (owner of both the curated
  room dir and the node-provisioned inventory dir, and the standing
  holder of the item) PUSHES the item to the taker. The taker never
  writes and never pulls.

  Two layers, composed transactionally:

    1. **Green-token possession** — a `Commonplace.Green.Bursar` token
       keyed on the item's uuid (`item_uuid` as the token path), NO TTL
       (permanent possession), identity-bound holder. Held by the node;
       TAKE transfers it node -> taker.
    2. **Tree-position durable record** — the item entry moves
       room-dir -> inventory-dir, committed elevated to node authority
       (both dirs are node-owned). This is the durable ownership
       record for v1.

  Safety-by-construction: elevation only ever fires when the ITEM being
  taken AND the taker's dest inventory are independently confirmed
  node-owned (mirrors `Commonplace.MUD.World.Facade.node_owned?/3`) — the
  item's node-ownership is the presence-robust "this is curated loot"
  signal, and the node-elevated source-remove is structurally bounded to
  removing that one item's entry (`Move` re-checks it is still there and
  removes it by name).

  NOTE (CX-ix9n live-fix): the gate deliberately checks the ITEM, NOT the
  source ROOM schema. A room schema's latest commit is re-chained by
  player PRESENCE writes (each `.usr` add/remove is signed by the
  entering/leaving player), so `node_owned?(room_schema)` flips false the
  moment anyone occupies the room — which wrongly refused every take in a
  populated room. Items and inventories are never presence-re-chained, so
  they are the reliable node-ownership oracle.
  """

  alias Commonplace.Crypto.{NodeIdentity, Signing}
  alias Commonplace.Green.{Bursar, BursarClient}
  alias Commonplace.MUD.{Move, Schemas}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema

  @players_dir "players"
  @inventory_name "inventory"

  @doc """
  Take `item_uuid` (entry `name`) from `room_uuid` into `inventory_uuid`
  on behalf of `taker_identity` (the taker's `signing_context.identity_uuid`).

  `opts`: `:store` (default `Commonplace.Store.CommitStoreClient`),
  `:bursar` (default `Commonplace.Green.Bursar`). Any `:ttl`/`:retries`/
  `:retry_ms` are passed through to `Move.move`.

  Returns `:ok` or `{:error, reason}` — `:bad_arg` (no/invalid taker
  identity), `:not_takeable_here` (the item or inventory dir is not
  node-owned, OR the source room fails the CX-1mz7 zone-gate — not
  shared-curated and not the taker's own home; no elevation, no writes),
  `:item_unavailable` (someone
  else already holds the item's possession token), `:taken` (lost a
  concurrent race for the token after the node held it), or whatever
  `Move.move/5` returns for the elevated tree-move (`:gone`,
  `:collision`, `:busy`, `:bursar_unavailable`, ...).
  """
  @spec take(String.t(), String.t(), String.t(), String.t(), String.t() | nil, keyword()) ::
          :ok | {:error, term()}
  def take(item_uuid, name, room_uuid, inventory_uuid, taker_identity, opts \\ []) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    bursar = Keyword.get(opts, :bursar, Bursar)

    # CHOKEPOINT "can this be taken" guard (CX-ix9n, plan #6675): a fixed
    # object is never takeable — enforce it HERE in the take primitive so it
    # can't be bypassed by a direct or container-take (`do_get_from`) caller,
    # not only by `do_take_plain`'s verb-layer `ensure_not_fixed`. Load
    # failures are NOT treated as fixed — the move below surfaces its own
    # error for a missing/non-object target.
    case item_fixed?(item_uuid, store) do
      true ->
        {:error, :fixed}

      false ->
        do_take_dispatch(item_uuid, name, room_uuid, inventory_uuid, taker_identity, store, bursar, opts)
    end
  end

  defp do_take_dispatch(item_uuid, name, room_uuid, inventory_uuid, taker_identity, store, bursar, opts) do
    # Common case — permissive mode, or an invoker who already holds write
    # authority over BOTH dirs (the item's owner). The invoker can make both
    # writes themselves, so run the move INVOKER-SIGNED, unchanged from the
    # pre-CX-ix9n behavior: no node elevation, no possession-token dance, and
    # no signed-identity requirement (permissive/unsigned sessions keep
    # working exactly as before). Node elevation is ONLY for the genuine
    # enforce visitor who lacks authority — mirrors the same
    # `invoker_can_write_all?` gate `World.Facade.write_guarded` applies
    # before it elevates an interactable write.
    if invoker_can_write_all?(opts, [room_uuid, inventory_uuid], store) do
      Move.move(item_uuid, name, room_uuid, inventory_uuid, invoker_move_opts(opts, store))
    else
      elevated_take(item_uuid, name, room_uuid, inventory_uuid, taker_identity, store, bursar, opts)
    end
  end

  # The enforce-visitor path: the invoker cannot make these writes, so the
  # node PUSHES the item (elevated to node authority) and hands the taker the
  # possession token. Requires a signed taker identity (always present under
  # enforce) to bind the token holder; without one, fail closed.
  defp elevated_take(_item_uuid, _name, _room_uuid, _inventory_uuid, taker_identity, _store, _bursar, _opts)
       when not is_binary(taker_identity) or taker_identity == "" do
    {:error, :bad_arg}
  end

  defp elevated_take(item_uuid, name, room_uuid, inventory_uuid, taker_identity, store, bursar, opts) do
    with {:ok, node_ctx} <- NodeIdentity.signing_context(),
         {:ok, node_identity} <- NodeIdentity.identity(),
         # CX-55o3 — judge the ITEM's node-ownership by the ACTUAL ownership
         # RECORD (the node-held possession token), NOT the fragile
         # schema-latest-signer proxy. The proxy flips FALSE the moment ANYTHING
         # re-chains the object dir schema — @verb (the verbs/ entry-add is
         # author-signed), @desc, presence — bricking take of a verb-bearing
         # object (same class as the CX-ix9n presence re-chain). The token is
         # immune: mint-at-create makes a @created/curated object node-held, and
         # verb-authoring/@desc NEVER touch the token. See `node_owns_item?/4`.
         true <- node_owns_item?(item_uuid, node_identity, bursar, store),
         # The dest inventory is a token-LESS dir; its node-ownership stays the
         # schema-signer check (node-elevated moves always node-sign it, so it
         # does not spuriously flip — dirs are not verb/@desc re-chained).
         true <- node_owned?(inventory_uuid, node_identity, store),
         true <- takeable_from_here?(room_uuid, inventory_uuid, opts, store) do
      do_take(item_uuid, name, room_uuid, inventory_uuid, taker_identity, node_ctx, node_identity, store, bursar, opts)
    else
      _ -> {:error, :not_takeable_here}
    end
  end

  # ---- CX-1mz7 TAKE-zone-gate (plan #6744/#6748): fail-closed positive allowlist ----
  #
  # The DROP/GIVE hard prereq. The item-keyed node-ownership gate above is
  # safe only by WORLD-STATE ASSUMPTION (node-owned takeables live only in
  # shared curated rooms). The moment DROP lands, a player can place a
  # node-owned item into a home — so a visitor standing in that home could
  # take it (both node-ownership checks pass). This gate closes that
  # home-raid: an item is takeable-from-here IFF the source room is
  # POSITIVELY one of:
  #
  #   (a) SHARED-CURATED — reachable from the world root via directory
  #       containment WITHOUT descending into the `players/` subtree; or
  #   (b) the TAKER'S OWN home zone — reachable from the taker's own player
  #       home dir (the `players/<taker>/` dir whose `inventory` entry IS
  #       this taker's `inventory_uuid` — a structural, unspoofable match).
  #
  # ANY other location — another player's home, an unrecognized/unreachable
  # dir, or a world with no resolvable root — REFUSES (fail-closed). This is
  # deliberately a POSITIVE allowlist, never a negative "not-under-another's-
  # home" test (which would be fail-OPEN for unclassified locations —
  # plan #6748). Mechanism is tree-location, which is presence-robust:
  # containment edges are dir entries, and presence `.usr` writes never
  # restructure them. It converges on the M2 zone-stamp (CX-4u03), which
  # will replace this O(curated-tree) reachability walk with an O(1) stamp
  # read.
  @doc """
  CX-2cmq — whether a NON-owner deposit of an item (currently in `from_dir`)
  into `container_uuid` may node-elevate under enforce. TRUE iff the invoker can
  already write the container themselves (their own zone → the invoker-signed
  path fires, no elevation needed) OR the container is a node-owned/curated zone
  by the SAME reachability gate extraction uses (`takeable_from_here?`).

  This is the deposit-side MIRROR of the extraction gate: a container a visitor
  cannot TAKE from, they also cannot DEPOSIT into. Without it, `deposit_item`'s
  `HolderMove.push` node-signs the container-add UNCONDITIONALLY, so a visitor
  over-elevates a write into ANY container — including a citizen's private home —
  which extraction then correctly refuses → the item is stranded (the CX-2cmq
  roach-motel). Gating deposit here makes both sides gate identically: curated →
  both open, citizen → both closed.
  """
  def deposit_elevation_allowed?(container_uuid, from_dir, opts, store \\ CommitStoreClient) do
    invoker_can_write_all?(opts, [container_uuid], store) or
      takeable_from_here?(container_uuid, from_dir, opts, store)
  end

  defp takeable_from_here?(room_uuid, inventory_uuid, opts, store) do
    case Keyword.get(opts, :root_uuid) do
      root when is_binary(root) ->
        own_zone_takeable?(room_uuid, inventory_uuid, root, store) or
          shared_curated_takeable?(room_uuid, root, store)

      _ ->
        # No resolvable world root — cannot POSITIVELY classify. Fail closed.
        false
    end
  end

  # (b) The source room is within the TAKER's OWN home subtree. The taker is
  # identified structurally by their node-owned inventory dir: their home is
  # the `players/` child dir whose own `inventory` entry is exactly this
  # `inventory_uuid` (no spoofable player-name needed).
  defp own_zone_takeable?(room_uuid, inventory_uuid, root, store) do
    case taker_home_dir(inventory_uuid, root, store) do
      nil -> false
      home -> reachable_contains?(home, room_uuid, nil, store)
    end
  end

  # (a) Shared-curated: reachable from the world root via dir containment,
  # with the `players/` subtree PRUNED so no home room ever counts as
  # shared. Positive reachability from the known curated root.
  defp shared_curated_takeable?(room_uuid, root, store) do
    reachable_contains?(root, room_uuid, players_dir_uuid(root, store), store)
  end

  defp taker_home_dir(inventory_uuid, root, store) do
    with players when is_binary(players) <- players_dir_uuid(root, store),
         {:ok, schema} <- Schemas.load_dir_schema(players, store) do
      schema
      |> Schema.list_entries()
      |> Enum.filter(&(&1.type == :dir))
      |> Enum.find_value(nil, fn home ->
        if home_inventory_uuid(home.node_id, store) == inventory_uuid, do: home.node_id, else: nil
      end)
    else
      _ -> nil
    end
  end

  defp home_inventory_uuid(home_uuid, store) do
    with {:ok, schema} <- Schemas.load_dir_schema(home_uuid, store),
         {:ok, entry} <- Schema.get_entry(schema, @inventory_name) do
      entry.node_id
    else
      _ -> nil
    end
  end

  defp players_dir_uuid(root, store) do
    with {:ok, schema} <- Schemas.load_dir_schema(root, store),
         {:ok, entry} <- Schema.get_entry(schema, @players_dir) do
      entry.node_id
    else
      _ -> nil
    end
  end

  @doc """
  CX-orlm — is `zone_uuid` a PLAYER-owned zone (rooted under `players/`)?

  The Facade elevation guard (AXIS 2) uses this to refuse node-elevating a
  visitor's write onto a player-owned zoned object. It reuses THIS module's
  `players/`-subtree reachability so possession (`Take`) and write-authority
  (`Facade.object_owner_authority`) share ONE zone-ownership notion — a player
  can't relocate their home out of `players/` without node authority, so
  `players/`-placement is the node-controlled structural proxy for "this zone is
  player-delegated".

  POSITIVE test, fail-OPEN: returns `true` ONLY when `zone_uuid` is provably
  inside the `players/` subtree. A `nil`/unresolvable zone, a missing
  `players/`, or a non-binary root returns `false` (NOT positively a player
  zone). This is deliberate — today's curated interactables are UNZONED
  (`doc_zone == nil`), and the primary elevation gate is the meta GENESIS signer
  (`node_owned?` on the write-authority axis); AXIS 2 only needs to exclude the
  FUTURE (CX-8yzt) player-OWNED ZONED objects, which carry a non-nil `players/`
  zone stamp. Fail-open here can never elevate a player object that AXIS 1
  hasn't already admitted (a player object gets invoker/unsigned meta genesis).
  """
  @spec player_zone?(String.t() | nil, String.t() | nil, GenServer.server()) :: boolean()
  def player_zone?(zone_uuid, root_uuid, store)
      when is_binary(zone_uuid) and is_binary(root_uuid) do
    case players_dir_uuid(root_uuid, store) do
      players when is_binary(players) -> reachable_contains?(players, zone_uuid, nil, store)
      _ -> false
    end
  end

  def player_zone?(_zone_uuid, _root_uuid, _store), do: false

  # DFS over directory containment from `start`, returning true as soon as
  # `target` is found. Never descends into `prune` (the `players/` subtree
  # for the shared check; `nil` for the own-home check). Cycle-guarded. Only
  # `:dir` entries are containment edges — presence `.usr` file entries are
  # ignored, so occupancy never changes the result.
  defp reachable_contains?(start, target, prune, store) do
    do_reach([start], target, prune, MapSet.new(), store)
  end

  defp do_reach([], _target, _prune, _seen, _store), do: false

  defp do_reach([uuid | rest], target, prune, seen, store) do
    cond do
      uuid == target ->
        true

      uuid == prune ->
        do_reach(rest, target, prune, seen, store)

      MapSet.member?(seen, uuid) ->
        do_reach(rest, target, prune, seen, store)

      true ->
        seen = MapSet.put(seen, uuid)
        children =
          case Schemas.load_dir_schema(uuid, store) do
            {:ok, schema} ->
              schema |> Schema.list_entries() |> Enum.filter(&(&1.type == :dir)) |> Enum.map(& &1.node_id)

            _ ->
              []
          end

        do_reach(children ++ rest, target, prune, seen, store)
    end
  end

  # (Mirror of `World.Facade.invoker_can_write_all?/2`.) The invoker is
  # authorized over EVERY target iff `Trust.writer_authorized?` — the
  # commitless mirror of the write-gate predicate — holds for each. Returns
  # `true` for everyone under permissive (`accept_unsigned`), and for the
  # owner/pinned identity under enforce; `false` for the uncerted visitor.
  defp invoker_can_write_all?(opts, uuids, store) do
    cfg = Commonplace.Trust.config()
    sc = Keyword.get(opts, :signing_context)
    identity = sc && sc.identity_uuid
    pub = sc && sc.public_key
    certs = Keyword.get(opts, :cert_cids, []) || []
    Enum.all?(uuids, &Commonplace.Trust.writer_authorized?(identity, pub, certs, &1, cfg, store))
  end

  # Invoker-signed move opts: thread the invoker's own signing context /
  # certs straight through (exactly what `do_take_plain` passed before), plus
  # any move tuning. NEVER carries a node signing context.
  defp invoker_move_opts(opts, store) do
    [store: store]
    |> Keyword.merge(
      Keyword.take(opts, [:signing_context, :cert_cids, :signer_id, :bursar, :ttl, :retries, :retry_ms])
    )
  end

  defp do_take(item_uuid, name, room_uuid, inventory_uuid, taker_identity, node_ctx, node_identity, store, bursar, opts) do
    with :ok <- ensure_node_holds(bursar, item_uuid, node_identity),
         {:ok, _} <-
           BursarClient.transfer(bursar, item_uuid, node_identity, taker_identity, authenticated_as: node_identity) do
      elevated_opts =
        [store: store, signing_context: node_ctx, cert_cids: []]
        |> Keyword.merge(Keyword.take(opts, [:bursar, :ttl, :retries, :retry_ms]))

      case Move.move(item_uuid, name, room_uuid, inventory_uuid, elevated_opts) do
        :ok ->
          :ok

        {:error, reason} ->
          # The move failed AFTER the token was already transferred to the
          # taker — roll back so the world stays consistent (item still in
          # room, token back to node). Best-effort: ignore the result.
          BursarClient.transfer(bursar, item_uuid, taker_identity, node_identity, authenticated_as: taker_identity)
          {:error, reason}
      end
    else
      {:error, {:not_holder, _}} -> {:error, :taken}
      {:error, _} = err -> err
    end
  end

  # Lazily ensure the node holds the item's possession token — no TTL
  # (permanent until transferred). NEVER calls `force_release`.
  defp ensure_node_holds(bursar, item_uuid, node_identity) do
    case BursarClient.query(bursar, item_uuid) do
      :available ->
        case BursarClient.acquire(bursar, item_uuid, node_identity, authenticated_as: node_identity) do
          {:ok, _} -> :ok
          {:denied, _} -> {:error, :item_unavailable}
          {:error, _} = err -> err
        end

      {:held, %{holder: ^node_identity}} ->
        :ok

      {:held, %{holder: _other}} ->
        {:error, :item_unavailable}

      # CX-sfj8/incident: a DOWN or unreachable Bursar (`{:error,
      # :bursar_unavailable}`, or any other query error) must surface a GRACEFUL
      # refusal — never `case_clause`-CRASH the player session. Without this
      # clause a Bursar outage took the whole session down mid-`take` instead of
      # a "you can't take that right now" reply.
      {:error, _reason} ->
        {:error, :item_unavailable}
    end
  end

  # Chokepoint takeability: only a `fixed: true` object is un-takeable. A
  # load failure (missing/non-object) returns `false` here so the move path
  # surfaces its own (`:gone`/`:not_found`) error rather than masking it as
  # `:fixed`.
  defp item_fixed?(item_uuid, store) do
    match?({:ok, %Schemas.Object{fixed: true}}, Schemas.load_object(item_uuid, store))
  end

  # CX-55o3 — the ITEM node-ownership oracle, keyed on the POSSESSION TOKEN (the
  # durable, identity-bound ownership RECORD) instead of the schema-latest-signer
  # PROXY. Robust to schema re-chaining by construction (verb-authoring, @desc,
  # presence re-chain the schema but NEVER the token):
  #
  #   * token node-held      -> node-owned (the live case: mint-at-create makes
  #     every @created/curated object node-held; @verb/@desc can't flip it).
  #   * token held-by-OTHER  -> NOT node-owned. THE ANTI-THEFT PIN: a player-held
  #     item can never be node-elevate-taken out of someone's hand.
  #   * token :available     -> fall back to the schema-signer check. This ONLY
  #     serves UN-MINTED node items (legacy/test seeds via create_dir_with_meta);
  #     in the live minted world the token is always held so this never fires
  #     (plan #7709 keeps it guarded rather than force-mint every test seed; the
  #     pure-token cleanup that drops it is CX-qph8). FORGE-SAFE: node_owned?
  #     READS the stored signer_id (it does not re-verify the sig), but the
  #     enforce write-gate already VERIFIED that signer_id's signature at write
  #     time, so a citizen cannot land a commit stamped with the node's id (no
  #     node key). A fork/import never yields a false node-ownership either: Fork
  #     mints fresh commits with NO node signing context (so the copy's signer_id
  #     does not parse to the node — proven in verb_take_brick_test PIN 3), and
  #     import/raw-write births are non-this-node-signed. See the fork-transplant
  #     + mint-site guardrails (plan #7701/#7702).
  defp node_owns_item?(item_uuid, node_identity, bursar, store) do
    case BursarClient.query(bursar, item_uuid) do
      {:held, %{holder: ^node_identity}} -> true
      {:held, %{holder: _other}} -> false
      _ -> node_owned?(item_uuid, node_identity, store)
    end
  end

  # Mirrors `Commonplace.MUD.World.Facade.node_owned?/3` — a doc is
  # node-owned iff its latest commit is signed by THIS node's identity.
  defp node_owned?(uuid, node_identity, store) do
    case CommitStoreClient.latest_commit(store, uuid) do
      {:ok, commit} ->
        match?({:ok, ^node_identity, _}, Signing.parse_signer_id(commit.signer_id || ""))

      _ ->
        false
    end
  end
end

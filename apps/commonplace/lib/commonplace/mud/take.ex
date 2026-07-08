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

  Safety-by-construction: elevation only ever fires when BOTH the
  source and dest dirs are independently confirmed node-owned (mirrors
  `Commonplace.MUD.World.Facade.object_owner_authority/2` /
  `node_owned?/3`) — a non-node-owned dir never gets node-elevated.
  """

  alias Commonplace.Crypto.{NodeIdentity, Signing}
  alias Commonplace.Green.{Bursar, BursarClient}
  alias Commonplace.MUD.{Move, Schemas}
  alias Commonplace.Store.CommitStoreClient

  @doc """
  Take `item_uuid` (entry `name`) from `room_uuid` into `inventory_uuid`
  on behalf of `taker_identity` (the taker's `signing_context.identity_uuid`).

  `opts`: `:store` (default `Commonplace.Store.CommitStoreClient`),
  `:bursar` (default `Commonplace.Green.Bursar`). Any `:ttl`/`:retries`/
  `:retry_ms` are passed through to `Move.move`.

  Returns `:ok` or `{:error, reason}` — `:bad_arg` (no/invalid taker
  identity), `:not_takeable_here` (room or inventory dir is not
  node-owned — no elevation, no writes), `:item_unavailable` (someone
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
         true <- node_owned?(room_uuid, node_identity, store),
         true <- node_owned?(inventory_uuid, node_identity, store) do
      do_take(item_uuid, name, room_uuid, inventory_uuid, taker_identity, node_ctx, node_identity, store, bursar, opts)
    else
      _ -> {:error, :not_takeable_here}
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
    end
  end

  # Chokepoint takeability: only a `fixed: true` object is un-takeable. A
  # load failure (missing/non-object) returns `false` here so the move path
  # surfaces its own (`:gone`/`:not_found`) error rather than masking it as
  # `:fixed`.
  defp item_fixed?(item_uuid, store) do
    match?({:ok, %Schemas.Object{fixed: true}}, Schemas.load_object(item_uuid, store))
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

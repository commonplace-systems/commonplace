defmodule Commonplace.MUD.HolderMove do
  @moduledoc """
  CX-cj3t.2 — DROP/GIVE under enforce: the holder-initiated push,
  shared by both verbs.

  Unlike TAKE (where the NODE holds the item and pushes it to the
  taker), DROP and GIVE start from the opposite possession state: the
  INVOKER already holds the item's green token. So the push direction
  inverts:

    * DROP pushes invoker -> node (the item lands in a node-owned room
      dir; the node becomes the new holder, making it takeable again,
      subject to the TAKE-zone-gate).
    * GIVE pushes invoker -> recipient (the item lands in the
      recipient's node-owned inventory dir; the recipient becomes the
      new holder).

  Both are the same shape: a green-token transfer FROM the invoker TO
  the new holder, followed by a node-elevated tree move (both source
  and dest dirs are node-owned, so the invoker's own signing context
  cannot write either one directly under `local_write_gate: :enforce`).

  ## Gate (a) — TOKEN-TRANSFER-FIRST (load-bearing)

  `BursarClient.transfer/5` runs BEFORE any elevated tree write, and it
  is authenticated `as: from_holder` — the invoker. This transfer
  succeeds ONLY if the invoker actually holds the token right now. That
  check IS the authorization check for the whole operation: there is no
  separate permission gate layered on top, because none is needed — you
  cannot drop or give away what you do not possess. A caller who tries
  to push an item they don't hold gets `{:error, :not_holder}` here,
  before the tree is touched at all.

  ## Rollback on move failure

  If the elevated `Move.move/5` fails AFTER the token already
  transferred (e.g. `{:error, :collision}` at the destination), the
  token is transferred back to the ORIGINAL holder (authenticated as
  the party that just received it) so the world doesn't end up with the
  item's structural location and its possession record disagreeing.
  This mirrors `Take.do_take/10`'s rollback exactly.

  Nobody ever pulls: every write in this module is a PUSH by whichever
  party already holds the thing being moved.

  ## CX-cogd — acquire-on-`:available`

  An item legitimately in the mover's own source dir may carry an
  `:available` (UNHELD) possession token — e.g. a node-minted economy
  item whose token was released (see CX-6567 for WHY that happens). The
  token-transfer-first gate above would refuse it `:not_holder`, so
  `ensure_mover_holds/7` ACQUIRES the unheld token for the mover first
  (the deposit/drop/give mirror of `Take.ensure_node_holds`), gated so
  the acquire is never a raid: only on the `:available` branch (no
  holder = no victim), and only when the mover is the node (node
  authority) OR the invoker can write the SOURCE dir (own-inventory
  pull). A token HELD BY ANOTHER party still falls through to the
  transfer and is refused `:not_holder` — the anti-raid guard is
  keyed on the durable token, never on tree location (CX-e8xj).

  RESIDUAL (non-atomic-CRDT class, plan-acknowledged, self-healing): a
  hard CRASH (process death, not an error return) BETWEEN the acquire
  and the move can orphan the freshly-acquired token to `:available` —
  a possession-LEAK, not a raid (no held token is lost, no unauthorized
  acquire occurs). It is the same non-atomicity `Move`'s cross-doc
  moves already live with, and it self-heals: the next handler
  re-acquires the `:available` token. Not gated on.
  """

  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Green.{Bursar, BursarClient}
  alias Commonplace.MUD.Move
  alias Commonplace.Store.CommitStoreClient

  @doc """
  Push `item_uuid` (entry `name`) from `from_dir` to `to_dir`,
  transferring green-token possession from `from_holder` to
  `to_holder`.

  Fast path (permissive mode, or an invoker with authority over both
  dirs): runs `Move.move/5` invoker-signed, unchanged — no token
  transfer needed since the invoker was already authorized to write
  both dirs directly.

  Enforce path (the invoker lacks authority over one or both dirs):
  transfers the possession token first (gate (a)), then elevates the
  tree move to node authority, rolling the token back on move failure.
  """
  @spec push(String.t(), String.t(), String.t(), String.t(), String.t() | nil, String.t() | nil, keyword()) ::
          :ok | {:error, term()}
  def push(item_uuid, name, from_dir, to_dir, from_holder, to_holder, opts \\ []) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    bursar = Keyword.get(opts, :bursar, Bursar)

    if invoker_can_write_all?(opts, [from_dir, to_dir], store) do
      Move.move(item_uuid, name, from_dir, to_dir, invoker_move_opts(opts, store))
    else
      elevated_push(item_uuid, name, from_dir, to_dir, from_holder, to_holder, store, bursar, opts)
    end
  end

  defp elevated_push(_item_uuid, _name, _from_dir, _to_dir, from_holder, to_holder, _store, _bursar, _opts)
       when not is_binary(from_holder) or from_holder == "" or not is_binary(to_holder) or to_holder == "" do
    {:error, :bad_arg}
  end

  defp elevated_push(item_uuid, name, from_dir, to_dir, from_holder, to_holder, store, bursar, opts) do
    with {:ok, node_ctx} <- NodeIdentity.signing_context(),
         {:ok, node_identity} <- NodeIdentity.identity(),
         # CX-cogd — an item legitimately in the mover's own source dir may carry
         # an :available (UNHELD) possession token (e.g. a node-minted economy
         # item whose token was released). The transfer below needs `from_holder`
         # to actually hold the token, so acquire it first — the deposit/drop/give
         # mirror of Take's `ensure_node_holds` acquiring an :available room item.
         # Returns `acquired?` so a downstream failure releases the acquire.
         {:ok, acquired?} <-
           ensure_mover_holds(item_uuid, from_holder, from_dir, node_identity, store, bursar, opts) do
      do_transfer_and_move(
        item_uuid, name, from_dir, to_dir, from_holder, to_holder, acquired?, node_ctx, store, bursar, opts
      )
    else
      {:error, {:not_holder, _}} -> {:error, :not_holder}
      {:error, :holder_mismatch} -> {:error, :not_holder}
      {:error, :not_held} -> {:error, :not_holder}
      {:error, _} = err -> err
    end
  end

  # CX-cogd — ensure `from_holder` holds the item's possession token so the
  # elevated transfer can proceed. Three-way, keyed on the TOKEN (not tree
  # location) so the anti-raid guard is exact:
  #   * held-by-`from_holder` → nothing to do (`{:ok, false}`).
  #   * held-by-OTHER → leave it; the transfer below refuses `:not_holder`
  #     (THE anti-raid guard — never pull a token out from under another holder).
  #   * :available (unheld) → ACQUIRE it for `from_holder`, but ONLY when that is
  #     the node (node authority, exactly like Take acquiring a public room item)
  #     OR the invoker owns the SOURCE dir (own-inventory pull). Never acquire an
  #     unheld token out of a dir the invoker can't write.
  # An :available token has no holder = no victim, so acquiring it is not a raid;
  # the write-authority gate is what keeps it scoped to your own goods.
  defp ensure_mover_holds(item_uuid, from_holder, from_dir, node_identity, store, bursar, opts) do
    case BursarClient.query(bursar, item_uuid) do
      {:held, %{holder: ^from_holder}} ->
        {:ok, false}

      {:held, %{holder: _other}} ->
        {:ok, false}

      :available ->
        if from_holder == node_identity or invoker_can_write_all?(opts, [from_dir], store) do
          case BursarClient.acquire(bursar, item_uuid, from_holder, authenticated_as: from_holder) do
            {:ok, _} -> {:ok, true}
            {:denied, _} -> {:error, :not_holder}
            {:error, _} = err -> err
          end
        else
          {:error, :not_holder}
        end

      {:error, _} ->
        {:error, :not_holder}
    end
  end

  defp do_transfer_and_move(item_uuid, name, from_dir, to_dir, from_holder, to_holder, acquired?, node_ctx, store, bursar, opts) do
    case BursarClient.transfer(bursar, item_uuid, from_holder, to_holder, authenticated_as: from_holder) do
      {:ok, _} ->
        elevated_opts =
          [store: store, signing_context: node_ctx, cert_cids: []]
          |> Keyword.merge(Keyword.take(opts, [:bursar, :ttl, :retries, :retry_ms, :precheck]))

        case Move.move(item_uuid, name, from_dir, to_dir, elevated_opts) do
          :ok ->
            :ok

          {:error, reason} ->
            # Move failed after the token moved to `to_holder` — roll BOTH back:
            # transfer the token back, then release the acquire if we made one
            # (net: the item stays put and the token returns to :available).
            BursarClient.transfer(bursar, item_uuid, to_holder, from_holder, authenticated_as: to_holder)
            if acquired?, do: BursarClient.release(bursar, item_uuid, from_holder, authenticated_as: from_holder)
            {:error, reason}
        end

      {:error, terr} ->
        # Transfer failed after a fresh acquire — release it so no token leaks.
        if acquired?, do: BursarClient.release(bursar, item_uuid, from_holder, authenticated_as: from_holder)
        normalize_holder_error(terr)
    end
  end

  defp normalize_holder_error({:not_holder, _}), do: {:error, :not_holder}
  defp normalize_holder_error(:holder_mismatch), do: {:error, :not_holder}
  defp normalize_holder_error(:not_held), do: {:error, :not_holder}
  defp normalize_holder_error(other), do: {:error, other}

  defp invoker_can_write_all?(opts, uuids, store) do
    cfg = Commonplace.Trust.config()
    sc = Keyword.get(opts, :signing_context)
    identity = sc && sc.identity_uuid
    pub = sc && sc.public_key
    certs = Keyword.get(opts, :cert_cids, []) || []
    Enum.all?(uuids, &Commonplace.Trust.writer_authorized?(identity, pub, certs, &1, cfg, store))
  end

  defp invoker_move_opts(opts, store) do
    [store: store]
    |> Keyword.merge(
      Keyword.take(opts, [:signing_context, :cert_cids, :signer_id, :bursar, :ttl, :retries, :retry_ms, :precheck])
    )
  end
end

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
         {:ok, _} <- BursarClient.transfer(bursar, item_uuid, from_holder, to_holder, authenticated_as: from_holder) do
      elevated_opts =
        [store: store, signing_context: node_ctx, cert_cids: []]
        |> Keyword.merge(Keyword.take(opts, [:bursar, :ttl, :retries, :retry_ms]))

      case Move.move(item_uuid, name, from_dir, to_dir, elevated_opts) do
        :ok ->
          :ok

        {:error, reason} ->
          BursarClient.transfer(bursar, item_uuid, to_holder, from_holder, authenticated_as: to_holder)
          {:error, reason}
      end
    else
      {:error, {:not_holder, _}} -> {:error, :not_holder}
      {:error, :holder_mismatch} -> {:error, :not_holder}
      {:error, :not_held} -> {:error, :not_holder}
      {:error, _} = err -> err
    end
  end

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
      Keyword.take(opts, [:signing_context, :cert_cids, :signer_id, :bursar, :ttl, :retries, :retry_ms])
    )
  end
end

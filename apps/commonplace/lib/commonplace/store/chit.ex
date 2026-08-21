defmodule Commonplace.Store.Chit do
  @moduledoc """
  A chit: git's commit object with the tree-hash replaced by a TREE-PIN.

  An immutable, content-addressed value object — one narrative claim of
  "the tree looked exactly like THIS at this moment, and it follows THAT
  prior moment." Stored in the CommitStore's CubDB under a `{:chit, cid}`
  row, joining the existing side-object convention (`{:attestation, id}`,
  `{:capability, id}`, `{:revocation, id}`, `{:sla_tombstone, id}`). A
  chit is NOT a doc commit: storing one never advances a `{:latest}` head
  and fires no PubSub — see `Commonplace.Store.CommitStore.store_chit/2`.

  ## The two layers (load-bearing)

  The ARTIFACT layer is `(tree_pin, parents, author, message,
  authored_at)`, and the `cid` is the SHA-256 of exactly those fields,
  canonicalized — it EXCLUDES `signature`/`signer_id`. The ENVELOPE layer
  is the signature pair, deliberately outside the content address: two
  minters of the same moment — same pin, same parents, same message, same
  artifact-derived timestamp — produce the SAME cid whether or not either
  of them signs, so the store deduplicates them by construction. The
  Ed25519 signature is over the cid, so it transitively covers every
  artifact field anyway — the same shape `Commonplace.Store.Commit` uses
  (sign the id, keep the signature out of the id).

  ## F5 determinism (why nothing here reads a clock)

  `authored_at` comes from the ARTIFACT layer, never wall-clock inside a
  mint: the caller passes it, derived from pinned content — in
  `Commonplace.Store.ChitMint` it is the checkpoint commit's own stored
  timestamp. Two mints of one moment must be byte-identical, so nothing
  in `new/5` or `content_address/5` may call `DateTime.utc_now/0` or
  `System.system_time/0` — the dedup-by-construction story above
  collapses the moment a wall clock leaks into a hashed field.

  ## Canonical form

  `tree_pin` is a `%{doc_uuid => commit_id}` map; a map has no stable
  wire order, so the content address sorts the entries by doc_uuid
  first. `parents` stays in CALLER order — parent order is meaningful
  (first parent = the branch line being advanced), exactly as in git.
  The canonical term is serialized with `:erlang.term_to_binary/2`
  `[:deterministic]` and hashed — the same canonicalization idiom
  `Commonplace.Store.SlaTombstone.content_address/1` and
  `Commonplace.Trust.Capability` use; do not invent another one.
  """

  alias Commonplace.Crypto.{Signing, SigningContext}

  defstruct [
    # binary — sha256 artifact hash (the content address)
    :cid,
    # %{doc_uuid (String) => commit_id (binary)} — the pinned subtree
    :tree_pin,
    # [binary] — parent chit cids (narrative claims; may be [])
    :parents,
    # String | nil — signer_id of the minter (artifact layer)
    :author,
    # String — the `commit -m` message
    :message,
    # integer — artifact-layer timestamp (see moduledoc, F5)
    :authored_at,
    # binary | nil — envelope layer, NOT in the content address
    :signature,
    # String | nil — envelope layer, NOT in the content address
    :signer_id
  ]

  @type t :: %__MODULE__{
          cid: binary(),
          tree_pin: %{optional(String.t()) => binary()},
          parents: [binary()],
          author: String.t() | nil,
          message: String.t(),
          authored_at: integer(),
          signature: binary() | nil,
          signer_id: String.t() | nil
        }

  @doc """
  Build a chit and stamp its content address.

  Pure — reads no clock, mints no randomness: the same five arguments
  always produce the same struct, cid included. `parents` is kept in
  caller order (order is meaningful); `tree_pin` is canonicalized inside
  `content_address/5`, so callers may pass the map in any construction
  order.
  """
  @spec new(map(), [binary()], String.t() | nil, String.t(), integer()) :: t()
  def new(tree_pin, parents, author, message, authored_at)
      when is_map(tree_pin) and is_list(parents) and (is_binary(author) or is_nil(author)) and
             is_binary(message) and is_integer(authored_at) do
    %__MODULE__{
      cid: content_address(tree_pin, parents, author, message, authored_at),
      tree_pin: tree_pin,
      parents: parents,
      author: author,
      message: message,
      authored_at: authored_at
    }
  end

  @doc """
  SHA-256 over the canonicalized ARTIFACT fields only — signature and
  signer_id never fold in (see moduledoc, "The two layers").

  Canonicalization: tree_pin entries sorted by doc_uuid (maps carry no
  stable order); parents in caller order; the whole tuple serialized via
  `:erlang.term_to_binary/2` `[:deterministic]` — the repo's existing
  content-address idiom (`SlaTombstone`, `Capability`, `Revocation`).
  """
  @spec content_address(map(), [binary()], String.t() | nil, String.t(), integer()) :: binary()
  def content_address(tree_pin, parents, author, message, authored_at)
      when is_map(tree_pin) and is_list(parents) and (is_binary(author) or is_nil(author)) and
             is_binary(message) and is_integer(authored_at) do
    sorted_pin = tree_pin |> Map.to_list() |> List.keysort(0)

    {sorted_pin, parents, author, message, authored_at}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  @doc """
  Recompute the artifact hash from the struct's fields and compare to
  the claimed `cid`.

  The store's write gate (`CommitStore.store_chit/2`) runs this BEFORE
  persisting — same id-gate-first posture as `Commit.verify_id/1` at
  `import_commit`: nothing about a chit's fields is trustworthy until
  its cid matches the hash of its own content.
  """
  @spec verify_cid(t()) :: :ok | {:error, {:cid_mismatch, binary(), binary()}}
  def verify_cid(%__MODULE__{} = chit) do
    computed =
      content_address(chit.tree_pin, chit.parents, chit.author, chit.message, chit.authored_at)

    if computed == chit.cid do
      :ok
    else
      {:error, {:cid_mismatch, computed, chit.cid}}
    end
  end

  @doc """
  Ed25519-sign the cid, filling the envelope layer (`signature` +
  `signer_id`). The cid is untouched — a signed and an unsigned chit of
  the same moment stay cid-equal (the dedup property). Same signing
  primitive as `Commonplace.Crypto.Signing.sign_commit/3` and
  `SlaTombstone.new/2`: raw `:crypto.sign/4` over the content address.
  """
  @spec sign(t(), SigningContext.t()) :: t()
  def sign(%__MODULE__{} = chit, %SigningContext{} = signing_context) do
    signature =
      :crypto.sign(:eddsa, :none, chit.cid, [signing_context.private_key, :ed25519])

    %{
      chit
      | signature: signature,
        signer_id: Signing.signer_id(signing_context.identity_uuid, signing_context.public_key)
    }
  end

  @doc """
  Verify the envelope signature over the cid against a public key.
  Returns `:ok`, `{:error, :unsigned}` for a bare artifact, or
  `{:error, :invalid_signature}`. Callers wanting full validity check
  `verify_cid/1` first — a signature over a forged cid proves only that
  someone signed the forgery.
  """
  @spec verify_signature(t(), binary()) :: :ok | {:error, :unsigned | :invalid_signature}
  def verify_signature(%__MODULE__{signature: nil}, _public_key), do: {:error, :unsigned}

  def verify_signature(%__MODULE__{} = chit, public_key) when is_binary(public_key) do
    case :crypto.verify(:eddsa, :none, chit.cid, chit.signature, [public_key, :ed25519]) do
      true -> :ok
      false -> {:error, :invalid_signature}
    end
  end
end

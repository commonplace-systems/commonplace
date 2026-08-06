defmodule Commonplace.Projection.PostState do
  @moduledoc """
  The **carried expectation**: `{encoding_version, hash}` of the doc state
  a writer actually produced, minted at write time and carried inside the
  commit's content address (and therefore under its signature).

  This is what separates the two verification grades in
  `Commonplace.Projection`:

    * **WITNESSED** — the commit carries a post-state hash, so a reader
      can reconstruct, canonically encode, hash, and compare against what
      the *writer* saw. Any replica judges offline; tamper breaks the
      comparison loudly.
    * **CORROBORATED** — no carried expectation exists (all history
      predating CX-6scm), so the ceiling is independent-path agreement,
      which says "consistent", never "what the writer saw".

  ## Why the version tag, and why never a bare hash

  `Yelixer.Encoding.encode_update/1` is byte-deterministic *within one
  encoder era* (`apps/yelixer/test/yelixer/encoder_determinism_test.exs`
  is the standing gate). It is NOT promised stable across eras.

  76dcd3c is the cautionary precedent: a Yelixer canonical-encoding
  change that shipped hours before this module was designed. Had post-
  state hashes been bare, that single change would have invalidated every
  prior WITNESSED mark at once — and the failure would have been
  **indistinguishable from tamper**, which is the exact confusion this
  layer exists to prevent.

  So the hash is always a PAIR. Bumping `@encoding_version` declares a new
  era: hashes minted under an older version are not compared against a
  newer encoder's output, they are reported as
  `{:corroborated, [:encoding_era_mismatch, ...]}` — honest, quiet, and
  distinguishable from `{:error, :hash_mismatch}`. Stability is required
  only PER VERSION TAG, verifiable per era, not forever.

  **The version-roll discipline** (the `snapshotter_version` precedent):
  any change to what `canonical_bytes/1` produces — in this module OR in
  `Yelixer.Encoding.encode_update/1` — MUST bump `@encoding_version` in
  the same commit. A silent encoder change under a stale version tag
  manufactures a fake tamper wave.
  """

  alias Commonplace.Store.Commit
  alias Yelixer.{Doc, Encoding}

  # Era 1: `Yelixer.Encoding.encode_update/1` as of CX-6scm (2026-08-06).
  # See "the version-roll discipline" in the moduledoc before changing.
  @encoding_version 1

  @doc "The current canonical-encoding era tag."
  @spec encoding_version() :: pos_integer()
  def encoding_version, do: @encoding_version

  @doc """
  Canonical bytes for a doc state — the one encoding the hash is taken
  over. Accepts a `Yelixer.Doc` or already-canonical bytes.
  """
  @spec canonical_bytes(Doc.t() | binary()) :: binary()
  def canonical_bytes(%Doc{} = doc), do: Encoding.encode_update(doc)
  def canonical_bytes(bytes) when is_binary(bytes), do: bytes

  @doc """
  Mint the carried expectation for a post-write doc state.

  Returns `{encoding_version, sha256(canonical_bytes)}` — never a bare
  hash (see the moduledoc).
  """
  @spec mint(Doc.t() | binary()) :: Commit.post_state_hash()
  def mint(state) do
    {@encoding_version, :crypto.hash(:sha256, canonical_bytes(state))}
  end

  @doc """
  Compare a commit's carried expectation against reconstructed state.

  Returns:

    * `:match` — the reconstruction reproduces exactly what the writer
      recorded (WITNESSED-eligible).
    * `:mismatch` — same era, different bytes. LOUD: either the
      reconstruction is wrong or the stored bytes were tampered with.
    * `{:era_mismatch, carried_version}` — the commit was minted under a
      different encoder era. NOT tamper; the comparison is simply not
      available, and the verdict falls back to the corroboration ceiling.
    * `:absent` — no carried hash (all pre-CX-6scm history).
  """
  @spec compare(Commit.t(), Doc.t() | binary()) ::
          :match | :mismatch | {:era_mismatch, non_neg_integer()} | :absent
  # Reads the field through `Commit.post_state_hash/1` rather than
  # pattern-matching it: pre-CX-6scm rows deserialise WITHOUT the key, so
  # `%Commit{post_state_hash: nil}` does not match them (see that
  # function's docs).
  def compare(%Commit{} = commit, state) do
    case Commit.post_state_hash(commit) do
      nil ->
        :absent

      {@encoding_version, hash} ->
        if :crypto.hash(:sha256, canonical_bytes(state)) == hash, do: :match, else: :mismatch

      {version, _hash} ->
        {:era_mismatch, version}
    end
  end
end

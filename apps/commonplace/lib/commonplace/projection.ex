defmodule Commonplace.Projection do
  @moduledoc """
  The ONE public pin-read API: `project_at/3`.

  Projection stops returning bare bytes. It returns bytes **with a
  verdict** — and the verdict is judged by state the chain itself carries
  (signatures, post-state hashes), never by trusting the reconstruction
  that produced the bytes.

  This module is CX-6scm's fix and the verified-projection layer at once
  (design: commonplace-plan `2026-08-06-verified-projection-design.md`;
  build brief: `docs/plans/2026-08-06-cx-6scm-verified-projection-build-brief.md`).

  ## The type change comes first

      project_at(doc_uuid, commit_id, opts) ::
          {:ok, bytes, verdict}    # verdict is never absent
        | {:unknown, reason}       # mixed-plane trip, conflicted paths, …
        | {:error, reason}         # store/signature/hash failure — loud

      verdict :: :witnessed
               | {:corroborated, [method]}
               | {:declared, path, disagreement}   # VP §7.7 R1

  An API without a declining outcome in its TYPE cannot underreport
  loudly even in principle — which is precisely why the old pin-read
  (`Reflog.Restore`'s `single_commit_doc` defp) could only ever hand back
  bytes, right or wrong. Every outcome above must be handled by every
  consumer; a consumer that pattern-matches only `{:ok, bytes, _}` fails
  review.

  ## The two grades (the honesty boundary)

  **WITNESSED** — the commit carries a post-state hash under its
  signature, so the reconstruction is checked against *what the writer
  actually produced*. See `Commonplace.Projection.PostState`.

  **CORROBORATED** — no carried expectation exists (all history predating
  CX-6scm: 77.1% of the 64,651 commit rows carry no signature at all, and
  none carry a post-state hash). The honest ceiling is independent-path
  agreement, and every method is **named in the verdict**. "Consistent",
  never "what the writer saw".

  Witnessed status cannot be minted retroactively — only earned at write
  time. A backfilled hash could only ever certify replay-consistency, so
  backfill stays corroborated-grade forever.

  ## The three tiers (§7.6, RULED 2026-08-06)

  The hard center, named honestly: **"is this commit full-state?" is not
  decidable from the commit alone.** A delta update also decodes
  standalone, so a single-commit read of a delta yields PARTIAL state
  silently — the same silent-wrong class this layer closes. Hence:

    * **(i) hash-bearing commits → arbitration.** Try the single-commit
      read; the carried hash matches → `:witnessed` via that state; else
      chain replay and compare; else loud `{:error, {:hash_mismatch, _}}`.
      Decidable forever. The hash stops being only a check and becomes
      the *decider*.

    * **(ii) HEAD pins on hash-less chains → the live read path as
      shipped is authoritative, by production precedent.** Every
      consumer, sync and display has been acting on live-path bytes;
      choosing replay would rewrite the meaning of the PRESENT.

      **But this codebase ships TWO head-read paths, and the census
      measures them disagreeing.** `DocBuilder.reconstruct_doc/3` (chain
      replay — snapshot-trim plus apply-since) is what content docs are
      read through; `DocBuilder.reconstruct_snapshot/3` (latest-commit
      read) is what schema/tree docs are read through via `DocCache`.
      They disagree at head on 80 of 2,384 `dir_schema` docs, 124 tree
      entries dropped by chain replay — CX-6scm's P1 — while for a
      delta-chain content doc it is the single-commit read that would
      return silent PARTIAL state. Neither is "the" live path corpus-wide.

      So tier (ii) reads both and **refuses to choose silently**. Agree →
      bytes, `:head_path_agreement`. Disagree → the caller's declared
      `head_path:` decides, at the `:declared` grade; undeclared →
      conflicted unknown. See `decide_head/5`.

      Guarded for TOCTOU: see "The tier-(ii) TOCTOU guard" below.

  ## The declaration is a fact about a population, not a preference

  Blessed at consensus (VP §7.7). `head_path:` is **not** the consumer
  choosing which truth it likes. It is the consumer stating **which
  production population its documents belong to** — "docs of this shape
  are read through `reconstruct_snapshot` by the running system" — which
  is a code-reviewed fact about the codebase, checkable by opening the
  reader.

  **The validity rule, review-enforced:** declare `:direct` ONLY for a
  population production actually reads through the latest-commit path
  (schema/tree docs via `DocCache`). **`:direct` over a delta-chain
  content doc is review-refusable** — there the single-commit read
  returns silent PARTIAL state, and a declaration cannot make partial
  state correct. Declare `:chain` only where production replays. State
  the reason at the call site, in the form
  `Commonplace.Reflog.Restore.single_commit_doc/3` uses: name the
  population and why it has that shape.

  Nothing here is machine-checked; it is review-enforced and named as
  such, which is the honest status.

  ## The grade ladder

      :witnessed  >  {:corroborated, methods}  >  {:declared, path, disagreement}  >  unknown

  `{:declared, path, disagreement}` is its own grade, strictly BELOW
  corroborated. It means: the two shipped paths disagreed, the caller's
  population-declaration selected these bytes, and the disagreement is
  carried in the verdict with both digests.

  The `:witnessed` and `:corroborated` floors **exclude** it. A consumer
  that asked for corroboration and could only be served declared bytes
  gets `{:unknown, {:conflicted, _}}` instead. This is the one place the
  floor is more than a budget, and deliberately so: without it, a
  declaration would launder DISAGREED bytes into export grade, and
  "chit export refuses a hole" would quietly stop being true. Display
  (`required: :any`) may take declared bytes; export may never.

    * **(iii) historical non-head pins on hash-less chains.** Where the
      single-commit read and the replay AGREE, either — verdict
      corroborated by `:path_agreement`. Where they DISAGREE →
      `{:unknown, {:conflicted, %{replay: _, direct: _}}}`, and this is
      **permanent** for pre-hash history. The strong form of why, kept
      verbatim from the ruling: *not "we chose not to decide" but "the
      information required to decide was never recorded"* — the writer's
      state was never witnessed, and no ruling can retroactively decide
      it.

  ## The tier-(ii) TOCTOU guard (CX-axdi family)

  Tier (ii) reads "the current state" — but `:latest` can advance while
  that read is in flight, and then the live path returns the NEW head's
  state, which is **the wrong bytes for the REQUESTED commit**, silently.

  So the "this commit IS head" classification must hold BEFORE **and
  AFTER** the live-path read. On a post-read mismatch the projection
  falls through to tier (iii), where the pin is a historical pin — which
  it now is — and agreement/conflict handles it honestly. The guard never
  returns tier-(ii) bytes it is no longer entitled to; the worst case is
  a conflicted-unknown, which is the truth.

  ## The consumer floor is a BUDGET, never a thumb on the verdict

  `required: :witnessed | :corroborated | :any` (default `:any`) lets a
  caller declare how much verification it is willing to pay for —
  corroboration costs real money (refold is 2× reconstruction) and reflog
  DISPLAY must not pay export-grade cost per render.

  Projection does the minimum work to reach the floor, **or returns the
  best achievable with a truthful verdict**. `required: :witnessed` on a
  hash-less chain returns a corroborated verdict; it never fabricates a
  `:witnessed` one. This is load-bearing and is tested, not merely
  stated.

  The floor is a budget for OPTIONAL corroboration only. It never buys
  out a tier's own decision procedure: tier (iii) runs both paths at
  every floor, because skipping the comparison to save a reconstruction
  would return silent partial bytes — the exact defect this layer exists
  to close.

  ## What this layer refuses

    * **No repair.** It reports; it never fixes.
    * **No silent oracle.** Every corroboration method is named in the
      verdict. "Verified" without saying *how* is the underreport pattern
      wearing a checkmark.
    * **No minting.** `project_at/3` never writes — not a lazy snapshot
      (`read_only: true` into `DocBuilder.reconstruct_doc/3`), not anything.
      A read that writes cannot be a verification primitive.
    * **No second projection path.** One API, one verdict, source-scan
      guarded (`test/commonplace/projection/caller_source_scan_test.exs`).
      A fast path that skips verification is the read-side sibling of a
      write that bypasses the gate.
  """

  alias Commonplace.Crypto.Signing
  alias Commonplace.Projection.{MixedPlane, PostState}
  alias Commonplace.Store.{Commit, CommitStoreClient}
  alias Commonplace.Tree.DocBuilder
  alias Yelixer.{Doc, Encoding}

  @type method :: atom() | {atom(), term()}
  @type verdict ::
          :witnessed
          | {:corroborated, [method()]}
          | {:declared, :chain | :direct, map()}
  @type floor :: :witnessed | :corroborated | :any
  @type result :: {:ok, binary(), verdict()} | {:unknown, term()} | {:error, term()}

  @floors [:witnessed, :corroborated, :any]

  # VP §7.7 R1 — the grade ladder, strongest first:
  #
  #   :witnessed  >  {:corroborated, _}  >  {:declared, _, _}  >  unknown
  #
  # `:declared` is its OWN grade BELOW corroborated, and the
  # `:witnessed` and `:corroborated` floors EXCLUDE it. A consumer that
  # asked for corroboration must never be handed bytes whose only
  # warrant is that the caller named a path — that would launder a
  # DISAGREEMENT into export grade, which is exactly the hole the
  # declaration form could otherwise open. Display-grade (`required:
  # :any`) may take declared bytes; export may never.
  @floors_excluding_declared [:witnessed, :corroborated]

  @doc """
  Project doc `doc_uuid` at pin `commit_id`, returning canonical bytes
  plus a verdict.

  Options:

    * `:store` — commit store server (default
      `Commonplace.Store.CommitStoreClient`).
    * `:required` — the consumer verification floor (see the moduledoc).
      Default `:any`.
    * `:head_path` — which shipped head-read path is authoritative for
      THIS caller when tier (ii)'s two paths disagree: `:chain`
      (`DocBuilder.reconstruct_doc/3`) or `:direct`
      (`DocBuilder.reconstruct_snapshot/3`). Default `:undeclared`, which
      returns conflicted-unknown on disagreement rather than guessing.

      **The declaration is not a preference — it is a claim of fact**,
      and the rule it must satisfy is below. Disagreement resolved by a
      declaration yields the `:declared` grade, not corroboration.
    * `:doc_opts` — forwarded to `Yelixer.Doc.new/1` for reconstruction
      (`:client_id`, `:clock_floor`).
    * `:require_head_reachable` — CX-ggdv. Use the pre-walk-bounding
      head-anchored chain walk (`DocBuilder.chain_to/4`) instead of the
      bounded backward walk. Same bytes, same verdict, more work; it
      exists so the two walks can be compared in one process and for the
      one caller that uses `:none` as an ancestry oracle. Default `false`.
  """
  @spec project_at(String.t(), binary(), keyword()) :: result()
  def project_at(doc_uuid, commit_id, opts \\ []) do
    case project_doc_at(doc_uuid, commit_id, opts) do
      {:ok, %Doc{} = doc, verdict} -> {:ok, PostState.canonical_bytes(doc), verdict}
      other -> other
    end
  end

  @doc """
  As `project_at/3`, but yields the reconstructed `Yelixer.Doc` instead of
  its canonical bytes.

  Same code path, same verdict, same refusals — this is a projection of
  the one result, NOT a second projection path. It exists because
  consumers that immediately re-decode the bytes (Reflog.Restore reading
  schema entries) would otherwise pay an encode/decode round trip to get
  back the doc projection already built.
  """
  @spec project_doc_at(String.t(), binary(), keyword()) ::
          {:ok, Doc.t(), verdict()} | {:unknown, term()} | {:error, term()}
  def project_doc_at(doc_uuid, commit_id, opts \\ []) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    required = Keyword.get(opts, :required, :any)

    unless required in @floors,
      do: raise(ArgumentError, "unknown :required floor #{inspect(required)}")

    with {:ok, commit} <- fetch_commit(store, doc_uuid, commit_id),
         {:ok, chain} <- fetch_chain(store, doc_uuid, commit_id, opts),
         {:ok, sig_method} <- verify_chain_integrity(chain) do
      commit
      |> select_tier(store, doc_uuid, chain, required, opts)
      |> add_method(sig_method)
      |> tripwire()
    end
  end

  # ── Fetch + cross-check ────────────────────────────────────────────

  defp fetch_commit(store, doc_uuid, commit_id) do
    case CommitStoreClient.get_commit(store, commit_id) do
      {:ok, %Commit{doc_uuid: other}} when is_binary(other) and other != doc_uuid ->
        # Defensive cross-check inherited from Reflog.Restore's
        # single_commit_doc/3: the pin a caller hands us should belong to
        # the doc uuid the caller believes it does.
        {:error, {:commit_doc_mismatch, commit_id, expected: doc_uuid, got: other}}

      {:ok, %Commit{} = commit} ->
        {:ok, commit}

      :none ->
        {:error, {:commit_not_found, commit_id}}
    end
  end

  # CX-ggdv: the walk is bounded — `DocBuilder.chain_to/4` walks BACKWARD
  # from the pin to the nearest snapshot instead of forward from `:latest`,
  # making pin reads O(distance-to-nearest-snapshot) rather than O(total
  # chain length). This is not a second projection path: it is the same
  # single path with the walk strategy as a parameter, and every verdict
  # downstream is a pure function of the chain this returns — so
  # chain-identity IS verdict-identity, which is what the neutrality
  # harness asserts.
  #
  # `require_head_reachable: true` selects the pre-CX-ggdv head-anchored
  # walk verbatim. Its only in-tree production user is
  # `Commonplace.Tree.Fork` (which uses `:none` as an ancestry oracle);
  # here it exists so old-path and new-path projections can be compared
  # byte-for-byte and verdict-for-verdict in one process against one store.
  defp fetch_chain(store, doc_uuid, commit_id, opts) do
    walk_opts = Keyword.take(opts, [:require_head_reachable])

    case DocBuilder.chain_to(store, doc_uuid, commit_id, walk_opts) do
      {:ok, chain} -> {:ok, chain}
      :none -> {:error, {:commit_not_on_chain, commit_id}}
    end
  end

  # ── Signature verification, threaded along the WALKED chain ────────
  #
  # Scoped honestly. This converts tamper from absorbed to LOUD for the
  # signed fraction of history — measured 2026-08-06 at 22.9% (14,810 of
  # 64,651 commit rows; the other 49,841 carry neither signature nor
  # signer_id). The remaining 77.1% stays at the corroboration ceiling
  # until it ages out behind hash-bearing new writes, and the verdict
  # says so rather than implying a check that did not happen.
  #
  # Two independent links are checked per commit:
  #
  #   1. the content address — recompute it from the fields PRESENT and
  #      compare to the claimed id. A flipped byte anywhere in `update`,
  #      `parent_id`, `metadata`, `merge_parents` or `post_state_hash`
  #      breaks this;
  #   2. the signature — verified against a PINNED key for the signer.
  #      A tamperer who also recomputes the id breaks this instead,
  #      because the signature was made over the ORIGINAL id.
  #
  # Either break on a signed commit is `{:error, :signature_invalid}`:
  # the signature no longer covers the bytes present. On an unsigned
  # commit only link 1 exists, and its break is
  # `{:error, {:content_address_mismatch, id}}` — loud too, but named
  # differently because it proves corruption, not forgery-resistance.
  defp verify_chain_integrity(chain) do
    cfg = trust_config()

    Enum.reduce_while(chain, {:ok, %{verified: 0, unsigned: 0, unpinned: 0}}, fn commit,
                                                                                 {:ok, tally} ->
      case classify_commit(commit, cfg) do
        {:ok, key} -> {:cont, {:ok, Map.update!(tally, key, &(&1 + 1))}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, tally} -> {:ok, signature_method(tally, length(chain))}
      {:error, _} = err -> err
    end
  end

  defp classify_commit(%Commit{} = commit, cfg) do
    address_ok? = Commit.content_address_of(commit) == commit.id
    signed? = Signing.signed?(commit)

    cond do
      not address_ok? and signed? -> {:error, :signature_invalid}
      not address_ok? -> {:error, {:content_address_mismatch, commit.id}}
      not signed? -> {:ok, :unsigned}
      true -> verify_signature(commit, cfg)
    end
  end

  defp verify_signature(%Commit{} = commit, cfg) do
    case pinned_keys(commit, cfg) do
      # An unpinned signer is NOT an error: most of this corpus predates
      # the trust config, and treating "I hold no key for you" as forgery
      # would make the tripwire fire on ordinary history — the reliable
      # way to get a check muted. It caps the verdict instead.
      [] ->
        {:ok, :unpinned}

      keys ->
        if Enum.any?(keys, &(Signing.verify_commit(commit, &1) == :ok)) do
          {:ok, :verified}
        else
          {:error, :signature_invalid}
        end
    end
  end

  defp pinned_keys(%Commit{signer_id: signer_id}, cfg) when is_binary(signer_id) do
    with {:ok, identity_uuid, _fp} <- Signing.parse_signer_id(signer_id),
         {:ok, pinned} <- Map.fetch(cfg.trusted_identities, identity_uuid) do
      pinned
      |> List.wrap()
      |> Enum.flat_map(fn encoded ->
        case Signing.decode_key(encoded) do
          {:ok, key} -> [key]
          {:error, _} -> []
        end
      end)
    else
      _ -> []
    end
  end

  defp pinned_keys(_commit, _cfg), do: []

  defp trust_config do
    Commonplace.Trust.config()
  rescue
    _ -> %{accept_unsigned: true, trusted_identities: %{}}
  end

  # The signature story is a NAMED method carrying its own denominators,
  # never a bare boolean — a count without its denominator is how "we
  # check signatures" comes to mean "we checked 0 of 40".
  defp signature_method(_tally, 0), do: nil

  defp signature_method(%{verified: v} = tally, total) when v == total,
    do: {:signatures_verified, Map.put(tally, :of, total)}

  defp signature_method(tally, total), do: {:signature_coverage, Map.put(tally, :of, total)}

  # ── Tier selection ─────────────────────────────────────────────────

  # Reads the carried hash through `Commit.post_state_hash/1`, never as a
  # struct pattern: legacy rows deserialise without the key.
  defp select_tier(%Commit{} = commit, store, uuid, chain, required, opts) do
    cond do
      not is_nil(Commit.post_state_hash(commit)) ->
        tier_i(commit, store, uuid, chain, required, opts)

      head?(store, uuid, commit.id) ->
        tier_ii(commit, store, uuid, chain, required, opts)

      true ->
        tier_iii(commit, store, uuid, chain, required, opts)
    end
  end

  defp head?(store, uuid, commit_id) do
    case CommitStoreClient.latest_commit(store, uuid) do
      {:ok, %Commit{id: ^commit_id}} -> true
      _ -> false
    end
  end

  # ── Tier (i): hash arbitration ─────────────────────────────────────

  defp tier_i(%Commit{} = commit, store, uuid, chain, required, opts) do
    direct = direct_state(commit, opts)

    case direct && PostState.compare(commit, direct) do
      :match ->
        {:ok, direct, :witnessed}

      _ ->
        replay = replay_state(chain, opts)

        case replay && PostState.compare(commit, replay) do
          :match ->
            {:ok, replay, :witnessed}

          {:era_mismatch, v} ->
            # NOT tamper. A different canonical-encoding era simply has no
            # comparison available, so the pin falls back to the ceiling
            # with the reason named (the 76dcd3c lesson, §5).
            fallback_from_hash(commit, store, uuid, chain, required, opts, {:encoding_era, v})

          :absent ->
            fallback_from_hash(commit, store, uuid, chain, required, opts, :hash_absent)

          _ ->
            {:error,
             {:hash_mismatch,
              %{
                commit_id: commit.id,
                carried: elem(Commit.post_state_hash(commit), 1),
                direct: digest(direct),
                replay: digest(replay)
              }}}
        end
    end
  end

  defp fallback_from_hash(commit, store, uuid, chain, required, opts, why) do
    result =
      if head?(store, uuid, commit.id) do
        tier_ii(commit, store, uuid, chain, required, opts)
      else
        tier_iii(commit, store, uuid, chain, required, opts)
      end

    add_method(result, why)
  end

  # ── Tier (ii): HEAD pin, live path authoritative, TOCTOU-guarded ───

  defp tier_ii(%Commit{} = commit, store, uuid, chain, required, opts) do
    before_id = latest_id(store, uuid)

    if before_id != commit.id do
      tier_iii(commit, store, uuid, chain, required, opts)
    else
      chain_state = head_state(store, uuid, :chain, opts)
      direct = head_state(store, uuid, :direct, opts)
      after_id = latest_id(store, uuid)

      cond do
        # The classification did not survive the read. `:latest` advanced,
        # so the states just read belong to the NEW head — wrong bytes for
        # the pin we were asked about. Fall through: the pin is a
        # historical pin now, and tier (iii) answers honestly (possibly
        # conflicted-unknown, which is the truth).
        after_id != commit.id ->
          tier_iii(commit, store, uuid, chain, required, opts)

        is_nil(chain_state) and is_nil(direct) ->
          {:error, {:reconstruction_failed, commit.id}}

        true ->
          decide_head(commit, chain_state, direct, required, opts)
      end
    end
  end

  # Tier (ii) reads the head through BOTH shipped read paths and refuses
  # to choose between them silently.
  #
  # The two paths the running system actually ships are
  # `DocBuilder.reconstruct_doc/3` (chain replay: snapshot-trim plus
  # apply-since — what content docs are read through) and
  # `DocBuilder.reconstruct_snapshot/3` (the latest-commit read — what
  # schema/tree docs are read through, via `DocCache`). Neither is "the"
  # live path corpus-wide, and the difference is not cosmetic: the census
  # in `test/fixtures/verified_projection/` measures 80 of 2,384
  # `dir_schema` docs where they disagree at head, 124 tree entries
  # dropped by chain replay (CX-6scm's P1) — while for a delta-chain
  # content doc it is the single-commit read that would return silent
  # PARTIAL state.
  #
  # So the caller declares which shipped path is ITS path, via
  # `head_path:`. Undeclared and the paths agree → bytes, corroborated by
  # `:head_path_agreement`. Undeclared and they disagree → conflicted
  # unknown. This is the design's own top-line rule applied at the tier
  # that most tempts a shortcut: **no silent choice anywhere**. Wrong
  # bytes are never returned to a caller that did not say which semantics
  # it wanted.
  defp decide_head(commit, chain_state, direct, required, opts) do
    declared = Keyword.get(opts, :head_path, :undeclared)
    agree? = not is_nil(chain_state) and not is_nil(direct) and same?(chain_state, direct)

    resolved =
      case declared do
        :chain -> chain_state
        :direct -> direct
        _ -> nil
      end

    cond do
      # The paths agree. The declaration did no work, so the grade is a
      # real corroboration — two independent shipped reads produced the
      # same bytes.
      agree? ->
        {:ok, chain_state, {:corroborated, [:head_path_agreement, {:live_head_path, :both}]}}

      # VP §7.7 R1: the paths DISAGREE and only the declaration resolves
      # it. That is the `:declared` grade — below corroborated — and the
      # floors that exclude it get the honest unknown instead. The
      # declaration decides which bytes; it does NOT upgrade what is
      # known about them.
      not is_nil(resolved) and required in @floors_excluding_declared ->
        conflicted_head(commit, chain_state, direct)

      not is_nil(resolved) ->
        {:ok, resolved,
         {:declared, declared,
          %{commit_id: commit.id, chain: digest(chain_state), direct: digest(direct)}}}

      true ->
        conflicted_head(commit, chain_state, direct)
    end
  end

  defp conflicted_head(commit, chain_state, direct) do
    {:unknown,
     {:conflicted,
      %{
        commit_id: commit.id,
        at: :head,
        chain: digest(chain_state),
        direct: digest(direct),
        resolvable_by: :head_path
      }}}
  end

  defp same?(a, b), do: PostState.canonical_bytes(a) == PostState.canonical_bytes(b)

  defp latest_id(store, uuid) do
    case CommitStoreClient.latest_commit(store, uuid) do
      {:ok, %Commit{id: id}} -> id
      _ -> nil
    end
  end

  # ── Tier (iii): historical pin on a hash-less chain ────────────────
  #
  # BOTH paths run at EVERY floor. See the moduledoc: a floor buys out
  # optional corroboration, never a tier's decision procedure. Returning
  # the single-commit read alone to save a reconstruction is exactly the
  # silent-partial-bytes hazard (§7.6 precision 2).
  defp tier_iii(%Commit{} = commit, _store, _uuid, chain, required, opts) do
    direct = direct_state(commit, opts)
    replay = replay_state(chain, opts)

    cond do
      is_nil(direct) and is_nil(replay) ->
        {:error, {:reconstruction_failed, commit.id}}

      is_nil(direct) or is_nil(replay) ->
        {:error, {:reconstruction_failed, commit.id}}

      PostState.canonical_bytes(direct) == PostState.canonical_bytes(replay) ->
        {:ok, replay, {:corroborated, [:path_agreement | refold(chain, replay, required, opts)]}}

      true ->
        # Permanent for pre-hash history. The information required to
        # decide was never recorded — the writer's state was never
        # witnessed — so this is not a deferral, it is the answer.
        {:unknown,
         {:conflicted, %{commit_id: commit.id, replay: digest(replay), direct: digest(direct)}}}
    end
  end

  # `:witnessed` on a hash-less chain cannot be reached. The floor is
  # honoured as a BUDGET — we spend the extra reconstruction the caller
  # authorised and report the strongest method it actually buys
  # (`:refold_stability`) — and the grade stays corroborated. Never a
  # fake `:witnessed`.
  defp refold(chain, reference, :witnessed, opts) do
    case replay_state(chain, opts) do
      nil ->
        []

      second ->
        if PostState.canonical_bytes(second) == PostState.canonical_bytes(reference) do
          [:refold_stability]
        else
          [{:refold_instability, %{second: digest(second)}}]
        end
    end
  end

  defp refold(_chain, _reference, _required, _opts), do: []

  # ── Reconstruction primitives ──────────────────────────────────────

  # F7: a genesis pin has a zero-byte update. `Encoding.apply_update` on
  # <<>> crashes, which is how the old `single_commit_doc` defp died on
  # genesis pins. A genesis pin IS the empty state, so it is answered as
  # one — never a crash, never `:none`.
  defp direct_state(%Commit{update: <<>>}, opts), do: Doc.new(doc_opts(opts))

  defp direct_state(%Commit{update: update}, opts) do
    case Encoding.apply_update(Doc.new(doc_opts(opts)), update) do
      {:ok, doc} -> doc
      _ -> nil
    end
  end

  defp replay_state(chain, opts) do
    Enum.reduce_while(chain, Doc.new(doc_opts(opts)), fn c, doc ->
      case Encoding.apply_update(doc, c.update) do
        {:ok, next} -> {:cont, next}
        _ -> {:halt, nil}
      end
    end)
  end

  # One of tier (ii)'s two shipped head-read paths, with minting
  # suppressed (`read_only: true`) so a verification read can never write —
  # and so it cannot perturb the very `:latest` pointer the TOCTOU guard
  # is reading.
  defp head_state(store, uuid, :chain, opts) do
    unwrap(DocBuilder.reconstruct_doc(store, uuid, [{:read_only, true} | doc_opts(opts)]))
  end

  defp head_state(store, uuid, :direct, opts) do
    unwrap(DocBuilder.reconstruct_snapshot(store, uuid, doc_opts(opts)))
  end

  defp unwrap({:ok, %Doc{} = doc}), do: doc
  defp unwrap(_), do: nil

  defp doc_opts(opts), do: Keyword.get(opts, :doc_opts, [])

  defp digest(nil), do: nil
  defp digest(%Doc{} = doc), do: :crypto.hash(:sha256, PostState.canonical_bytes(doc))

  # ── Verdict plumbing ───────────────────────────────────────────────

  defp add_method(result, nil), do: result

  defp add_method({:ok, doc, {:corroborated, ms}}, method),
    do: {:ok, doc, {:corroborated, [method | ms]}}

  # `:witnessed` stays the bare atom and `{:declared, _, _}` keeps its
  # exact shape. The grade IS the contract; appending methods would
  # silently reshape the type consumers match on. A witnessed pin has
  # nothing left to corroborate, and a declared pin must not accumulate
  # methods that make it read like a corroborated one.
  defp add_method(other, _method), do: other

  # ── The mixed-binding tripwire, at PIN reads (F9) ──────────────────

  defp tripwire({:ok, %Doc{} = doc, verdict}) do
    case MixedPlane.scan(doc) do
      :ok -> {:ok, doc, verdict}
      {:trip, details} -> {:unknown, {:mixed_plane, details}}
    end
  end

  defp tripwire(other), do: other
end

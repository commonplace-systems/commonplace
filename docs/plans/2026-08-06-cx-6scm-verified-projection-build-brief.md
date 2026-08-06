# CX-6scm build brief: the verified-projection fix

2026-08-06. This is the build brief for CX-6scm (P1: chain replay
silently drops entries on full-state-rewrite chains), built AS the
verified-projection layer's first delivery — the fix is the layer, per
jes's correctness-first directive and boss's framing ("build it as the
P1 fix and the layer falls out — don't build the layer speculatively
and hope the P1 lands inside it").

**Authorities, all consensus-final:**
- Verified-projection design @05345de
  (`/home/jes/commonplace-plan/docs/plans/2026-08-06-verified-projection-design.md`),
  including §7.5 (mint-side guards) and §7.6 (the three-tier semantics
  ruling with both precisions).
- The chit sizing report (2026-08-06 session record; harness preserved
  in the sizing worktree) — findings F1–F9.
- Signed-commit census: **22.9%** of the 64,651 commit rows carry a
  signature (14,810; the other 49,841 have neither signature nor
  signer_id). Signature-threading converts tamper from absorbed to
  loud for under a quarter of existing history; the corroboration
  ceiling governs the rest until it ages out.
- The conflicted-pins census artifact (in flight from the sizing
  harness): the 27 A≠B pins + the 80 head-disagreement docs, with both
  candidate hashes each — acceptance-test input.

## Scope IN

1. **`project_at(doc_uuid, commit_id, opts)` — the ONE public pin-read
   API** (the F3 promotion), returning
   `{:ok, bytes, verdict} | {:unknown, reason} | {:error, reason}`,
   verdict `:witnessed | {:corroborated, [method]}`. Placed per the
   design (§4): Reflog.Restore's `single_commit_doc` logic subsumes
   into it; every reconstruct-at-commit caller reroutes through it; a
   **source-scan guard over reconstruct-at-commit callers** proven red
   by injection (third application of the CX-jfok pattern).
   Genesis pins handled (F7: zero-byte update never crashes — a
   genesis pin is the empty state, `{:ok, empty, verdict}`).

2. **The §7.6 three-tier semantics:**
   - (i) hash-bearing commits → **arbitration**: try single-commit
     read; carried hash matches → `:witnessed` via direct state; else
     chain replay + compare; else loud `{:error, :hash_mismatch}`.
   - (ii) HEAD pins on hash-less chains → **the live read path AS
     SHIPPED is authoritative** (P1 precision: snapshot + apply-since
     machinery, NOT raw single-commit read — a delta at head is
     handled by production machinery and undecidability never bites at
     this tier). The 80 docs get the live path's bytes at head, by
     ruling; chain replay is wrong there by ruling.
   - (iii) historical non-head pins on hash-less chains → where
     single-commit read and replay AGREE, either; where they DISAGREE
     → `{:unknown, {:conflicted, %{replay: sha, direct: sha}}}` —
     permanent for pre-hash history. The record states the strong
     form: **the information required to decide was never recorded**
     (the writer's state was never witnessed), not "we chose not to
     decide."

3. **Signature verification threaded into the projection walk** (§3.1)
   — scoped honestly: converts tamper to loud for the 22.9% signed;
   unsigned history stays at the corroboration ceiling and the verdict
   says so.

4. **Post-state hash minting** at the BUILD pipeline, not the
   `put_latest` funnel: `post_state_hash: {encoding_version, hash}`
   inside signed content (canonical encoding; the version tag is the
   76dcd3c lesson — a Yelixer encoding change must be distinguishable
   from tamper, per-era). Requires the **Commit.new caller enumeration
   at code resolution** (CommitBuilder is the main pipeline;
   CrossEpochMerge, prebuilt-merge, Snapshotter mint directly — each
   threads its post-state or is named legacy-compatible) and the
   **§7.5 source-scan guard: a hash-less commit can only originate
   from named legacy-compatible sites**, red-proven.

5. **The mixed-binding tripwire at pin reads** (F9): projection runs
   the mchn detect-only tripwire on reconstructed-at-pin state; a trip
   → `{:unknown, {:mixed_plane, details}}`, never bytes. The armed doc
   `235d73b5…` at its pin 2-of-5 is the live control.

6. **Consumer verification floor** (`required: :witnessed |
   :corroborated | :any`): a floor is a BUDGET, never a thumb on the
   verdict — projection does the minimum work to reach the floor or
   returns the best achievable, and the verdict always states what was
   actually checked.

## Scope OUT (each with its owner)

- **Walk-bounding** (performance): strictly AFTER this lands; must not
  change which bytes anything returns — this brief's fix decides
  bytes, walk-bounding makes the same bytes cheaper.
- **Repair** of the 80/124 (human-gated, the 905-char rule; tier (ii)
  defines *current state*, recovery reads are tier-(iii) pins — the
  ruling does NOT bless k20z-style live losses).
- **Backfill corroboration marks**, chit export, require-hashes-at-
  Gate-A: later, separately.
- `reconstruct_doc`'s lazy-snapshot write-on-read (CX-68m6) — separate
  ticket; this build only ensures `project_at` itself never mints.

## Acceptance (pre-declared; every control red-proven before its green counts)

1. Flipped byte in a SIGNED commit → `{:error, :signature_invalid}`,
   loud, on every signed chain class. Unsigned-chain tamper stated
   truthfully: refold-stability survives it; only oracle/live-head
   corroboration can catch some — the verdict grade reflects the
   ceiling, and the test asserts the grade, not a miracle.
2. Constructed mixed-plane doc at its pin → `{:unknown,
   {:mixed_plane,_}}`; the armed doc is control #2.
3. **The 80-doc head-disagreement corpus: at head, 80/80 return the
   LIVE path's bytes with a truthful verdict (tier ii); at their
   disagreeing historical pins, conflicted-unknown per tier (iii)** —
   counts with denominators against the census artifact.
4. Known-good doc at head + deep pin → `{:ok, bytes, verdict}`,
   correct grade, byte-identical across two fresh processes.
5. New commit minted with hash → projects `:witnessed`; hash field
   tampered → loud. Both directions.
6. Mint on round N of a full-state-REWRITE chain → verify PASSES
   (the F2-interaction case).
7. **P2 precision: a constructed KNOWN-DELTA commit must never emerge
   `{:ok,…}` via single-commit read absent hash-match or
   path-agreement** — require conflicted-or-replay, never silent
   partial bytes.
8. Both source-scan guards (caller-side and mint-side) red-proven by
   injection, injection removed, stated where.

## Discipline

Worktree off current main; TDD; per-app test runs with counts checked;
`--warnings-as-errors`; CI status checked before merge (deploy
checklist step 0); no live-serve contact; the 76dcd3c rule — this goes
first WITH the same review it would have gotten going second.

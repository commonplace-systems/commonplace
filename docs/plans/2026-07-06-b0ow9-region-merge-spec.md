# CX-b0ow.9 spec — GitBridge G2 true region-merge (anchor-replica full)

Author: commonplace (Fable design/review; Sonnet implements). Inputs:
CX-b0ow.9 bead (mechanism sketch), CX-b0ow.2 (G2 v1 — conflicts on ANY
concurrent CRDT edit), writer-identity W2 (the bridge's persistent hand),
Yelixer mint path reality (`Types.Text` et al: new-op clock =
`StateVector.get(BlockStore.state_vector(store), doc.client_id)`).

## 0. The property being bought

Region-disjoint concurrent edits SURVIVE on both sides: git-side edit B
lands via Yjs merge against CRDT-side concurrent edit A, instead of v1's
conflict-file bail. Same-region overlap still converges (may read oddly)
with the pre-merge git version preserved at the conflict path — the
conflict path becomes preservation-for-review, not rejection (brief §3.5
unchanged).

## 1. The mechanism (from the bead, made precise)

1. Reconstruct the REPLICA at the ANCHOR commit
   (`DocBuilder.reconstruct_doc_at/3`) with the bridge's stable hand as
   `client_id` — **plus a clock floor** (§2) so new mints can't collide
   with bridge ops that landed between anchor and `:latest`.
2. Apply the git diff as text splices to the replica (v1's existing
   splice code).
3. `U = Yelixer.Encoding.encode_diff(replica_after, anchor_sv)` where
   `anchor_sv` is the replica's state vector captured BEFORE splicing —
   U contains exactly edit B's new blocks (+ full delete set; DS
   application is idempotent, dupes are fine).
4. Reconstruct the LIVE doc at `:latest` (`reconstruct_doc/3`, read-only
   client_id irrelevant), `apply_update(live, U)` — YATA merges B with
   concurrent edit A; B's origins reference anchor-state items, which
   the live doc has, so integration is position-independent.
5. Encode the MERGED live doc (full state) and
   `create_chained_commit` off **`:latest`** (not the anchor) — this is
   what makes the result stay on the chain instead of forking it.
   Use the caller-side CAS path; on `:parent_moved` REDO from step 4
   with the new latest (replica + U stay valid — U is anchored, not
   latest-relative). Bound the redo loop (3 attempts) then fall back to
   v1's conflict-preservation path.

## 2. The clock floor — the one Yelixer change

**Why:** the replica at anchor has the bridge hand's clock at
`anchor_sv[hand]`. If the bridge minted inbound ops between anchor and
latest, `latest_sv[hand] > anchor_sv[hand]`, and step 2's mints would
reuse taken (hand, clock) ids — silently skipped as duplicates when U
hits the live doc (the same collision class reproduced in the CX-41qg.3
review). The floor makes replica mints start at `latest_sv[hand]`.

**Yelixer API:** `Doc.new/1` gains opt `clock_floor: n` (stored on the
Doc, default 0, `%{client => n}` NOT needed — floor applies to the
doc's own `client_id` only). All local mint sites currently read
`StateVector.get(BlockStore.state_vector(store), doc.client_id)` —
centralize that read into ONE helper `Yelixer.Doc.mint_clock/1`
returning `max(sv_clock, doc.clock_floor)` and convert every type
module's mint site (text, array, y_map, xml_element, xml_fragment,
xml_text — grep for the `StateVector.get(BlockStore.state_vector`
pattern) to call it. Pure refactor + max().

**Hazards to document on the opt (moduledoc, verbatim intent):**
- A floored doc's FULL state must never be shipped as an update to a
  peer that lacks the gap blocks — post-gap blocks would sit in the
  receiver's pending buffer forever. The bridge only ever ships
  `encode_diff` output (B's blocks), applied to the live doc which HAS
  the gap blocks. State this as the usage contract: floor is for
  derived/throwaway replicas whose output is diff-encoded into a doc
  that owns the missing range.
- Floors are local-only: nothing about the wire format changes; yrs
  compatibility untouched (add a test proving encode bytes of a
  non-floored doc are unaffected by the refactor — the 5320-case yrs
  corpus is the real pin here and must stay green).

**Bridge side:** `GitBridge.Inbound.mint_edit` computes
`floor = StateVector.get(latest_sv, bridge_hand)` (latest_sv from the
live doc reconstruction it needs anyway) and passes
`clock_floor: floor` when reconstructing the anchor replica.
(`reconstruct_doc_at/3` needs to accept/forward `Doc.new/1` opts the
same way `reconstruct_doc/3` learned to in CX-41qg.3.)

## 3. What does NOT change

- v1's anchor bookkeeping (sidecar anchors), splice computation, echo
  prevention, and the same-region conflict-preservation path stay.
  The ONLY branch that changes is "anchor != latest" (concurrent CRDT
  edit): v1 bails to conflict; v2 runs §1 and only bails if the CAS
  redo bound is exhausted.
- Outbound direction unchanged.
- No new identity machinery: the bridge's existing stable hand (W1/W2
  conventions) is reused; the floor is bookkeeping, not a new hand.

## 4. Test pins

1. **The headline:** file F at anchor; CRDT-side edit A to region 1
   (via CommandRouter); git-side edit B to region 2 (disjoint);
   inbound sync → BOTH edits present in the merged doc AND in the
   re-exported file; no conflict file.
2. **Clock-continuation (THE subtle pin):** two successive inbound
   git edits with a concurrent CRDT edit between them — the second
   inbound edit's ops must NOT collide with the first's (assert the
   second edit's text survives replay; without the floor this test
   MUST fail — verify by temporarily zeroing the floor while
   developing, like CX-ziye's proof-by-stash, and note the result in
   the report).
3. Same-region overlap: both edits to one region → doc converges (no
   crash, deterministic), pre-merge git version preserved at the
   conflict path (v1 behavior retained for review).
4. CAS redo: a `:parent_moved` mid-merge (inject a concurrent write
   between reconstruct-latest and commit) → merge redoes and lands.
5. Yelixer: mint_clock refactor — full yelixer suite (incl. the yrs
   dataset) green; floored-doc unit test (floor respected, diff-encode
   contains floored clocks, applying to a doc owning the gap
   integrates, non-floored behavior byte-identical).
6. Full corpus green.

## 5. Constraints

DO NOT SPAWN SUBAGENTS. NEVER use run_in_background — all commands
foreground. No `bd`/.beads, no push. Don't touch chat/web/MUD/trust
files (parallel build owns MUD). Yelixer changes are wire-invariant
refactors + the floor opt ONLY. mix compile --warnings-as-errors clean.
Verification order: yelixer suite → git_bridge tests → full core →
commit "CX-b0ow.9: true region-merge — anchor-replica with clock-floor
continuation".

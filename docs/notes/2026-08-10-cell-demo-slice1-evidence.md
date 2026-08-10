# Cell demo, slice 1 — the §6 composition rehearsal: evidence

> STATUS: COMPLETE (2026-08-10 22:47Z). Every claim below is measured — read
> back from the cell store, the git reflog, or a captured evidence log under
> `/home/jes/cell-1/evidence/` — never inferred from a command's exit status.

Acceptance: assessment §5 (plan's), as amended by the CX-b38c ruling (msg
11099) and the reduced-world addendum (msg 11114). Decomposition:
`docs/plans/2026-08-10-cell-demo-slice-decomposition.md`.

## The one-paragraph honest summary

A cell was born via the real init path, its punctuation commit rode a tapped
git through the proto-chit emitter into its own CRDT store, the pinned
candidate carries a signed witness record from a second standing principal,
and the subtree-cert machinery was demonstrated with three controls. **The
world was REDUCED: 19 declared excludes, ~110 files (the yelixer contribution
surface plus the repo top level); full-world acceptance is explicitly gated on
CX-tj6b.** "Demo green" must not read as "cells work on real repos." And per
plan's wording constraint, verbatim: **cert-scoped write demonstrated for
NON-CODE writes; code authoring rides node trust today, BY DESIGN of the
write⊥execute belt; gap filed CX-b38c, shape ruled.**

## The rehearsal earned its name: findings ledger

The demo's stated purpose (§6) was that composition is where surprises live.
Six real findings were filed before the first event landed, every one invisible
to the pilot's toy world:

| # | Ticket | Finding | Status/ruling |
|---|--------|---------|---------------|
| 1 | CX-g8r1 [p1] | sync import crashes on binary files (hardcoded :text, String.length on invalid UTF-8) | ⛔ BINDING ORDER (plan, msg 11104): must NOT land ahead of the scope policy or its declared stopgap — the crash is the accidental protector |
| 2 | CX-fm7x [p1] | sync scope was everything-minus-four-names; in this repo that aimed 123 credential-adjacent `.darc` archives at the cell store, saved only by the binary crash firing first | Plan ruled: MANIFEST-DECLARED scope; denylist and gitignore-as-authority REJECTED; lean = git-tracked set; invariant adopted: imported = enumerable from the pin, excluded = declared, never inferred, declaration pin-referencable |
| 3 | CX-fadm [p2] | substrate mints `bd/` + `chat/` schema entries into every fresh workspace root; an import-only cell can never converge them | Workaround = declared excludes; design smell feeds #12 cell manifests |
| 4 | CX-tj6b [p1] | emission re-sync on a POPULATED store balloons unboundedly — detect_changes reconstructs EVERY doc's full content per pass. Killed the operating session (cgroup OOMPolicy=stop cascade) and took the live serve as collateral | Plan + jes: NEXT IN BUILD LANE after this ceremony. Small-world datapoint: the ~110-file emission completes in <5s end to end (faster than the 5s RSS sampler's first tick); the 1,230-file world exceeded 10GB RSS without converging, twice |
| 5 | CX-z0sa [p1] | a SIGTERMed emitter exits 0 (BEAM graceful shutdown), so the shim's exit-status-keyed WAL fallback reads a killed emission as SUCCESS: real git proceeds with NO event and NO envelope — invisible to F1 forever | Fix property: WAL decision keys on POSITIVE persist confirmation, never exit status |
| 6 | CX-zfzn [p1] | sync apply_delete produced a signed commit that RE-ASSERTS the entry it was deleting (full-state re-encode of an ineffective remove); apply_changes discards every write result | Mechanism discriminator open (pending-item remove vs settled fold); the untrustworthy-deletion path stands regardless of the ceremony's unblock |

Interim unblock for #6/#3, landed for this ceremony: symmetric excludes —
`exclude_names` invisible to the sync diff in BOTH directions. Built by an
Opus worker, merged @23ac0b0 (fix @feed926). Red-first evidence recorded in
the worker's run: 3 new tests red on unmodified code (excluded schema-only
entry surfaced as `:deleted`; recursion DELETED the excluded entry from the
root schema — the one-sided exclude was destructive, not merely noisy;
excluded name with differing content surfaced as `:modified`), control green
before and after; core suite 3290 tests / 1 failure = the known CX-5e8s
greet-race, green in isolation.

## L1 — cell birth via the real init

Attempt-2 cell (attempt-1's store preserved as evidence at
`/home/jes/cell-1/store-attempt1`, including its 5-envelope WAL):

- Root: `2513e08b-86ab-4c70-9c70-3d7d6b79dd9b` (`evidence/10-birth2.log`)
- Cell principal: `5bf5ed1a-1859-4c49-83fd-476dd52888ac`, Ed25519 via the
  first-class CLI path (`keygen default` + `secret set signing_identity`),
  fingerprint in `evidence/11-keygen2.log`
- The serve's identity is deliberately NOT reused; the cell signs as itself.
- CX-vvbh loudness note: the self-trust error line fires once during a healthy
  first boot, before the identity mints (`evidence/10-birth2.log` line 1) —
  cosmetic, noted, not pursued tonight.

## Declared world scope (the CX-fm7x stopgap, not the design)

`PROTO_CHIT_SYNC_EXCLUDES`, appended to un-droppable defaults
(`.git,.commonplace,_build,deps`), every name a declaration:

```
.beads .claude .github .stateproj bd chat bin data demo docs scripts tmp
tools fixtures commonplace commonplace_bots commonplace_cli commonplace_mcp
commonplace_web
```

Resulting world: ~110 text files — `apps/yelixer` (minus `.beads`, `docs`,
`test/fixtures`) plus repo top-level files plus `config/` and `test/`. This is
declared-not-inferred configuration under plan's ruling: **it buys the demo,
not the design** — the scope POLICY remains manifest-declared (CX-fm7x).
`fixtures` exclusion also keeps CX-g8r1's nine remaining binary files out of
the import path without touching the crash (binding order respected).

## L3 — tap + F1's instrument

- Shim: worktree-local tap-through (`/home/jes/cell-1/toolchain/bin/git`),
  emitter built from main @a164fa7/ea319e5 (excludes pass-through merge).
- ⭐ F1's loud line fired correctly on every WAL-bearing invocation, and git
  was never blocked — the condition plan inserted before the demo paid for
  itself the same night (`evidence/07-tapped-commit.log`,
  `evidence/12-commit2.log`).
- Event log doc: `1d6426f4-1b24-44f4-91ec-c2f2a586fb2b`.

## Step 3 — the real change (CX-lgfg)

Built by Sol under its normal contract, unstaged handoff, wire format
untouched: `XMLElement.reregister_root_tag/3` — replay reconstructs a named
root as `:unknown` (the tag is not carried on the Yjs wire), `to_string` emits
corrupt `<>` tags; the promoted API upgrades absent/`:unknown`, is idempotent
on same-tag, and RAISES on conflicting registration (the workaround's
blindness removed). Red-first replay-corruption assertion kept in the test.

## Step 4 — punctuation ✅

Tapped `reset --soft HEAD^` + `commit -F` through the fixed emitter
(`evidence/13-reset2.log`, `evidence/14-commit3.log`), both inside a
memory-capped scope; punctuation git commit **`10a8e50c`**. Verified by
READING THE EVENTS BACK from the cell store (RedLog over event-log doc
`1d6426f4`), never inferred from git success:

- **event 0** `verb=rewrite`, author `5bf5ed1a` (the cell), git-sha
  annotation `02ac9915` (pre-op HEAD), proto-pin
  `commonplace-reflog-path-pin/v1` checkpoint `973fd5fb…`, **91 pinned
  entries**, predecessor-refs `[]` (first event on branch)
- **event 1** `verb=commit`, author `5bf5ed1a`, git-sha annotation
  `1f94ace4` (pre-op HEAD), checkpoint `33dfed58…`, 91 entries,
  **predecessor-ref = event 0's enclosing commit** (`babd6e9f…`) — the
  punctuated-history chain advancing for real
- both event commits SIGNED by the cell principal (`signer_id
  5bf5ed1a…@525e6f6f`); `predecessors.json` advanced to event 1's ref
  (`47a36ee8…`), which is therefore **the CANDIDATE pin**

Known design note for step-1b (F2 ruling): the git-sha annotation is captured
pre-exec; the post-exec resulting-sha annotation is the ruled follow-up.

F1's instrument on the way here: the 02ac9915 attempt's failed emission WALed
loudly (`evidence/12-commit2.log`, "1 pending unsigned envelopes") and that
envelope remains in `toolchain/state/events.wal.ndjson` as evidence — replay
disposition per F3's ruling is not exercised tonight and is declared as such.

## L6 — cert scope: three controls ⏳

Cert: `{:subtree, zone_root}` `[:write]`, minted by the workspace node
identity for the CELL principal. Run captured at
`evidence/15-cert-controls.log` (enforce + strict trust armed in-harness;
the workspace's persistent posture untouched): node identity `5a9c359b`,
cell principal `5bf5ed1a` (fp `525e6f6f`), zone root `90d9082a`, inside doc
`13c8130c`, cert `2a3ca69ccc…`. Per plan's ruling the third control stays
prominent:

1. ✅ non-code write INSIDE the subtree under the cert → **LANDED**
   (`{:ok, "3de85fe569cfff81"}`, cell-signed, capability_proof carried)
2. ✅ write OUTSIDE the subtree → **DENIED**
   `{:error, {:trust_rejected, :capability_insufficient}}`
3. ✅ CODE-classified write INSIDE the subtree under the cert → **ALSO
   DENIED** (same doc, same cert, same signer as control 1 — only the
   content class differs, which isolates the belt as the discriminating
   cause) — **the write⊥execute belt working, not failing**: a write-only
   cert that could plant auto-executing code would be exactly the laundering
   hole the belt exists to close (trust.ex:534).

Observation, recorded not filed tonight: controls 2 and 3 share the reason
atom `:capability_insufficient` — the denial does not NAME the belt; the
attribution above rests on the control-pair design, not the error shape.

Cell code writes ride the cell workspace's own node identity — L1 as designed.
The attenuated-code-authoring destination is (i)-shaped (explicit capability;
route (iii) ruled NOT a route); mechanism round owed by plan before L2.

## L5 — witness ✅

`evidence/16-witness.log`. The serve identity (`commonplace_dev`, verified
enforce-BY-EFFECT at 22:10Z: `local_write_gate: :enforce`, `accept_unsigned:
false`, root `6fd72a7f`) ran the targeted yelixer suite at the pinned commit
— **25 tests, 0 failures**, with a nonzero-count assertion so an
umbrella path-drop cannot fake green — and signed a witness record into the
cell store:

- witness doc `9b7a8a56-ee46-4b15-90a9-9a6c3673c68d`, commit `f7f14d71…`
- `signer_id eed47143…@5b04a026` (the serve's standing identity) — verified
  by re-reading the stored commit, and **≠ cell principal `5bf5ed1a`**: the
  independence that §5 requires is a fact of the store, not an assertion
- verdict grade `:corroborated` in the VP vocabulary; candidate = git sha
  `10a8e50c` + event ref `47a36ee8…`
- the enclosure states verbatim: same box, same operator; independence is
  the PRINCIPAL only; suite run in the cell worktree at the pin, not an
  independent checkout; world reduced (19 excludes, ~110 files, CX-tj6b
  gates full-world); box-level independence is L2's story.

## Containment record

The near-miss on `.beads` (attempt 1) was closed by independent verification
(boss-clod, msg 11102): credential key 0600 at its original path, no
credential-shaped file in any `.commonplace` store, the moved archives
accounted for in `cell-1/holdout`. The population-move was restored at 22:44Z
via `git checkout -- .` in the cell worktree (123 `.darc` archives back,
tree clean at the pin — which the witness's clean-tree gate itself enforced
by refusing to run until the restore happened). `cell-1/holdout` retained as
redundant evidence.

Session-integrity note, because it belongs to this rehearsal's record: the
ceremony's first full-world emission attempt OOM-killed the operating
session's entire tmux scope (cgroup `OOMPolicy=stop` cascade) and took the
live serve as collateral; the serve was relaunched with the documented
Mode-B line, moved by boss-clod into a dedicated scope, and re-verified by
effect. All later emissions ran under `systemd-run --scope -p MemoryMax=6G`
so a balloon dies alone and its death is a measurement.

## What this demo does NOT claim

- No L4 federation (slice 2, plan's ack A). No L2 runner; the cell's key sits
  in the cell workspace — the gap the runner closes (custody ruling).
- No records-accrue-natively, no authority flip: git stays authoritative.
- Not "cells work on real repos": full-world emission is CX-tj6b-gated.
- Not "cert-scoped code contribution": see the verbatim constraint above.

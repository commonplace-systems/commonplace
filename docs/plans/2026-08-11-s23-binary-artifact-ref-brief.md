# S23 build brief: binary content as artifact references — the ruled destination

> Transcribed from plan's design doc
> (commonplace-plan docs/plans/2026-08-11-binary-artifact-ref-design.md
> @a0ce79c — read it FIRST; it is the authority and this brief its
> execution form). Ruled in direction at S1a staging, endorsed by jes
> verbatim ("yeah i think content addressed makes more sense"). The rs
> era's opaque-inline tier was TRIED AND DROPPED — its failure modes are
> this build's red tests.

## The build

1. A `:binary` ContentType whose doc holds NO content bytes — an
   explicit envelope in a Yjs map (explicit fields, never key-absence):
   `{cid, size, mode, classified_by}`. `cid` points into the EXISTING
   content-addressed artifact store (the CAS tree pins and @-refs
   already resolve — no new storage tier).
2. Classification at import — FACTS, NEVER GUESSES:
   - `:invalid_utf8` — a measurement (such a file cannot be a text
     doc; routing is forced).
   - `:declared_extension` — the extension appears in a DECLARED list
     seeded from the rs `detect_from_path` inventory
     (commonplace-rs/src — convert the heuristic to a declaration),
     carried with the sync scope config, amendable like any
     declaration.
   - ⛔ NO CONTENT SNIFFING IN EITHER DIRECTION, EVER. No
     looks-like-base64, no text-that-might-be-binary. A valid-UTF-8
     file with an UNDECLARED extension imports as TEXT — if that is
     ever wrong, the fix is a declaration, not a heuristic.
3. Merge: the envelope updates ATOMICALLY (one commit sets the map
   fields). Concurrent updates converge deterministically; convergence
   ≠ coherence is STATED in the module doc; both blobs stay
   CAS-reachable and the losing commit stays in history (the evidence
   a later conflict projection needs, without building its UI).
   ⛔ Nobody merges bytes — no byte-level merge path by construction.
4. Write-back: ref → fetch cid → write bytes → apply mode. Failure at
   ANY step = loud skip with the named reason, previous file left
   INTACT. ⛔ NEVER write envelope JSON or anything else as the file's
   bytes (the rs corruption path — decode failure wrote raw base64 to
   disk with a warn — is the explicit red-first).
5. The S1 floor REMAINS for anything the classifier does not cover;
   its declared skips stay valid history; its population shrinks but
   never silently disappears. Scope (fm7x) stays distinct:
   classification happens INSIDE declared scope.
6. Pins: a binary doc pins like any doc; the pin's entry carries
   `classified_by` (imported = enumerable-with-reasons).

## ⛔ Escape hatches, up front

- If the existing CAS/artifact store lacks a streaming read/write
  seam and one would need building, stop and report the seam (the
  flat-RSS arm depends on it).
- If the declared-extension list's rs inventory can't be located or
  converted mechanically, report what you found and seed from the
  measured population instead (the .bin/.cub/.ico/escript set the S1
  floor logged today is a real starting inventory) — say which you
  used.
- A new durable record shape beyond the envelope map is plan's — stop.

## Acceptance arms (§8 of the design doc, verbatim intent)

1. ROUND-TRIP FIDELITY: import → write-back byte-identical,
   hash-verified, for BOTH classification routes.
2. THE RS CORRUPTION RED: fetch failure at write-back refuses loudly
   and leaves the prior file untouched — red-first against a naive
   implementation that writes what it has.
3. MEMORY: large-binary import with FLAT RSS, measured (the tj6b arm —
   the reason inline died; state the file size and the measurement).
4. MERGE: concurrent envelope updates converge; both blobs
   CAS-reachable; losing commit in history.
5. NO-SNIFF PIN: a valid-UTF-8 file with an undeclared extension
   imports as TEXT, asserted (the guess-path stays dead).

## Out of scope, named (§9)

Semantic unpack (jes's fence: "much much later"); inline small-binary
optimization; conflict-resolution UI; binary diff.

## Gates

Sync/watcher/content-type + new test files, then FULL core suite (mix
test apps/commonplace/test) + `mix compile --warnings-as-errors`;
counts reported. Tmp stores only. sol-run.log is the OPERATOR'S
artifact — never delete it; no repo-wide formatting; work UNCOMMITTED.

## Deliverable

Report: the envelope as shipped, the declared-extension list and its
provenance, all five arms' evidence (red-firsts verbatim, the RSS
measurement with file size), test counts, deviations.

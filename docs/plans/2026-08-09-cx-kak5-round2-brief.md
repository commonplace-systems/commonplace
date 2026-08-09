# BUILD BRIEF — CX-kak5 round 2: the target is `yjs-preview`

**For:** Sol (codex)
**Ticket:** **CX-kak5** (p2/bug)
**Round 1:** `docs/plans/2026-08-09-cx-kak5-brief.md` — ⭐ **you stopped and
reported a contradiction instead of improvising, and that was exactly right.**
The finding invalidated the ticket's premise. This brief supersedes round 1's
§2 (the mandated package) and §4 (acceptance).

---

## 0. Environment contract (standing)

Unchanged from round 1 §0. Named worktree off **current** `origin/main`; git
metadata read-only, **leave changes UNSTAGED**; no serve route; suites one at a
time via `bin/cp-test-guard`; **rc from the command itself, never a pipe**;
**a count from a piped listing is not a count**.

## 1. ⛔ THE RULING: target `yjs-preview`, not `yjs-stable`

Round 1 told you to import `'yjs-stable'`. **That was wrong and it is my
error, not yours.** Measured since:

**All seven generators are v14-authored — zero v13-style calls between them.**
v14 unified-type usage (`.get(`, `setAttr`, `getAttrs`, `deleteAttr`) appears
14 / 5 / 41 / 5 / 1 / 68 / 3 times across the seven; `getText(` / `getMap(` /
`getArray(` / `new Y.Text` appear **0 times in every file**.

⇒ `yjs-stable` (13.6.32) would break **all seven**, not just the one that
currently runs. **Import `'yjs-preview'`.**

⭐ **Why preview rather than converting them to v13 — the second reason is
decisive:**
1. They were **authored** against v14; preview makes them what they already
   are, and it is the one-line change.
2. ⭐ **Converting to v13 would change the fixture BYTES by definition** — and
   acceptance requires **byte-identical** regeneration. **The conversion branch
   cannot satisfy the criterion that exists to protect the fixtures.**
3. It matches jes's policy — *"new features track the preview release"* — which
   is why `f87d43e` taught the port v14 `xml_fragment`.

**Answered deliberately so nobody inherits it:** **fixtures track preview;
live conformance covers both lines** (`diff_yjs`, CX-wzkr). Committed fixtures
assert v14 interop; stable interop is asserted live against `yjs-stable`. They
cover different things and do not conflict.

## 2. ⛔ The real state — worse and more interesting than "a stale path"

**Liveness depends on where the repo is checked out.** Measured both ways:

| | from `/home/jes/commonplace` | from any worktree |
|---|---|---|
| resolve | **3** | **1** |
| dead | **4** | **6** |

- **DEAD EVERYWHERE (4)** — `'../../yjs/src/index.js'`, which would need
  `apps/yelixer/yjs/` and that has never existed:
  `complex_interop.mjs`, `generate.mjs`, `roundtrip.mjs`,
  `verify_yelixer_in_yjs.mjs`
- **LOCATION-DEPENDENT (2)** — `'../../../../../yelixer/yjs/src/index.js'`
  counts five levels up from the fixtures dir, landing on `/home/jes/` **only**
  when the repo sits at `/home/jes/commonplace`; a worktree is at a different
  depth and it dies: `yjs_oracle.mjs`, `yjs_verify.mjs`
- **ALIVE (1)** — absolute path: `multi_commit_generator.mjs`

⚠️ **So four of these have not run in a long time**, and nothing noticed
because **nothing executes them** — every suite stays green either way. **Same
class as a dark branch: absence of execution reads identically to success.**

## 3. Work

Point all seven at `'yjs-preview'`. That is the whole mechanical change.

⛔ **Then find out what actually happens when each one runs**, which is the part
that matters and the part nobody has done.

## 4. Acceptance — paste real output

1. **Census returns zero, reported UNPIPED:**
   `grep -rlE "from '.*yjs/src/index\.js'" apps/yelixer/test/fixtures/*.mjs`
2. ⭐ **Run each of the seven and report what happened, one line each.**
   Expect several to fail for reasons **beyond** the import — they have been
   dead long enough to have rotted in other ways.
   ⛔ **Report those, do not fix them.** A generator that now fails on a
   changed API, a missing argument, or an absent input file is a **finding**,
   not this ticket's work. **Do not let a pre-existing failure read as one you
   caused, and do not resurrect four dead scripts inside a re-pointing
   ticket.**
3. ⭐ **`multi_commit_generator.mjs` must regenerate `multi_commit_fixtures.json`
   BYTE-IDENTICALLY.**
   ⛔ **AND IT MUST FIRST PROVE THE GENERATOR WROTE THE FILE — this criterion as
   originally written was unfalsifiable.** An unchanged file means *"regenerated
   identically"* OR *"never written"*, and a hash comparison cannot tell them
   apart. Sol hit exactly this: `before d1f8ced1… / after d1f8ced1… / cmp rc=0`
   while the generator had **crashed before writing** — the check produced its
   passing output *because* the work did not happen, and would do so on every
   future run. ⇒ **Positive control required: assert the process exited 0 AND
   the mtime advanced, before comparing bytes.**

   It is the one generator that currently works, so it is the one that can
   prove the swap is behaviour-preserving. ⛔ **If the bytes differ, STOP AND
   REPORT** — that is a finding about the fixture or the version, not a licence
   to commit new bytes.
   ⚠️ Note it currently resolves an **absolute** path into the stale clone,
   whose Yjs is a **v14 rc**; `yjs-preview` is **14.0.0-16**. **If the bytes
   differ, that difference IS the answer to "does the pinned preview match the
   clone", and it is worth more than a green.**
4. **Resolution comes from `node_modules`:** from the fixtures dir,
   `node --input-type=module -e "console.log(await import.meta.resolve('yjs-preview'))"`
   resolves inside the worktree.
5. `apps/yelixer/test` green with counts — **1 doctest, 33 properties, 390
   tests on main.** `mix compile --warnings-as-errors` rc=0.
6. **Name any criterion you could not verify in-sandbox** and stop rather than
   approximating.

## 5. Out of scope

- `yjs_diff_driver.mjs` — **do not touch** (CX-3mj2 + CX-wzkr own it).
- **Repairing generators that fail for non-import reasons** — report them.
- Committing regenerated fixture bytes.
- Any other defect: **report it, don't fix it.**

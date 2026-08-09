# BUILD BRIEF — proto-chit step 1a: the git write-verb tap-through shim + THE EVENT SCHEMA

**For:** Sol (codex) · **plan's #1 — a FEATURE** (jes: *"can we direct towards feature work"*)
**Worktree:** `/home/jes/sol-chit1a/wt` · **branch:** `sol/proto-chit-1a`
**Run log:** `/home/jes/sol-chit1a/sol-run.log`

---

## 0. Environment contract (standing)

Named worktree off **current** `origin/main`; ⛔ leave changes **UNSTAGED**, no
`git add`, no commit, no push; ⛔ **no serve, no live store** — the live store is
`/home/jes/commonplace/workspace/.commonplace/commits/`, **process-derived, NOT
repo-root and NOT `data/`**. ⚠️ **`mix deps.get` first.**

⚠️ **rc from the command itself, never through a pipe.** ⛔ **NO BARE ZEROS** —
any `0` arrives with a positive control that the pattern matches something.

⚠️ **You will be writing a PATH shim named `git`. ⛔ DO NOT install it on any
PATH outside your worktree, and do not modify your own shell's PATH in a way
that outlives the run.** A shim named `git` that escapes is a foot-gun for every
other process on this box.

## 1. What this is

The record lives in the **substrate**; the local `.git` is disposable
scaffolding. v1 is **TAP-THROUGH** — a split of git's verb surface:

- **Read verbs stay real** (`status`/`diff`/`log` hit the local `.git`). Tools
  orient by reading git constantly; emulating porcelain from the substrate is a
  large unmeasured integration and is explicitly refused.
- **Write verbs are tapped** (`commit`/`branch`/`checkout`/`merge`): a small
  shim earlier in PATH **fires the punctuation event, then execs real git** so
  the scaffolding stays consistent.

⭐ **Acceptance for step 1 is ZERO GIT-BYTE CHANGE.** The GitHub side must not be
able to tell. That triviality is the point of tap-through over stubs.

## 2. ⭐⭐ THE LOAD-BEARING DELIVERABLE IS THE SCHEMA, NOT THE SHIM

⛔ **The event schema is the contract true chit will consume, and it must be
reviewable AS DATA — not inferred from the shim's behaviour.**
commonplace-plan's pins-from-spec review is **gated on this artifact existing**.

⇒ **Produce `docs/plans/2026-08-09-proto-chit-event-schema.md` as a standalone
spec** — field by field, each with its type, its source, and what it is NOT.

**Fields, per the roadmap §2:**

| field | notes |
|---|---|
| `verb` | one of `commit` / `merge` / `branch` / `rewrite` |
| `author-principal` | ⭐ **signed via the gated write path** |
| `message` | the human message |
| `proto-pin` | ⭐ **real pin format, sync-flushed** — not a placeholder |
| `predecessor-ref` | per branch |
| `git-sha` | ⛔ **ANNOTATION ONLY** |

⚠️ **Write down the open questions you could not settle rather than choosing
silently.** ⭐ A schema with three honestly-marked unknowns is more useful to the
review than one that reads as settled and is not.

## 3. ⛔ The refusals — these are design rulings, not preferences

1. ⛔ **No git-sha as event identity.** Annotation only.
2. ⛔ **No unsigned events.** ⭐ **A shim that cannot reach the gated write path
   WALs — it never writes raw.** State what your WAL does and where it lands.
3. ⛔ **No untapped rewrite verbs.** Silent divergence is the migration trap;
   if a write verb is not tapped, **name it explicitly as untapped** rather than
   leaving the set implicit.
4. ⛔ **Do not claim records-accrue-natively.** This is the onramp's evidence and
   machinery, not Stage 1.

## 4. ⛔ Acceptance — artifacts

1. ⭐ **The schema document** (§2), standalone and reviewable without reading
   the shim.
2. **The shim**, small and readable, with the tapped verb set explicit.
3. ⭐⭐ **ZERO-GIT-BYTE-CHANGE, DEMONSTRATED:** run a real `git commit` through
   the shim in a scratch repo and show the resulting **object/ref bytes are
   identical** to the same commit made without the shim. ⛔ *"It still works"*
   is not the criterion — **compare bytes** (e.g. `git cat-file`/`git
   rev-parse` on a fixed-timestamp commit, or a `.git` tree hash).
4. ⭐ **The tap FIRED, proven separately from git succeeding** — show the event
   payload the shim produced. ⚠️ **A shim that execs git correctly and emits
   nothing passes every check in #3.**
5. ⭐ **The unsigned-path refusal, exercised:** make the gated write path
   unreachable and show the event **WALs rather than writing raw or vanishing.**
   ⛔ Without this, refusal #2 is a claim rather than a behaviour.
6. `mix compile --warnings-as-errors` rc=0.

## 5. ⛔ Suites — NAMED BY BLAST RADIUS

⚠️ This adds an emission path that reaches the **gated write path**, so it is
not confined to new files. **Baseline each FIRST, report both numbers, one at a
time, rc from the command itself:**

- `apps/commonplace/test/commonplace/trust` — **213 tests, 0 failures on main**
- `apps/commonplace/test/commonplace/store` — **baseline it and report both**
- `apps/commonplace_cli/test` — **baseline it and report both**

⭐ *(Measured on main at `dbf8ab6`. Older briefs quoting 195/196/197/201/206/210
for trust are stale.)*

⚠️ `BotPresenceCertTest` times out in the FULL mud suite on main (present in
main's own run) and is unrelated. `CommitHoistTest` is load-marginal (CX-qzbh).
One line each if seen; move on.

## 6. Scope

- **Pilot scope is the Sol sandbox + ONE checkout.** ⛔ Do not wire this into
  the live serve, and do not touch `/home/jes/commonplace`.
- ⛔ **Step 1b (the outer mirror / live-synced git folder) is NOT in this
  ticket.** Do not start it.
- ⛔ Do not touch chit itself, the invariant registry, the verified-projection
  layer, or anything described as the authority flip.
- Any other defect: **one line, don't pursue it.**

## 7. What you cannot verify in-sandbox

- ⛔ Anything requiring the live serve — report **UNVERIFIED** and stop.
- ⭐ **Everything in §4 is buildable from a scratch git repo and a fixture
  store.** If you find yourself needing the live workspace, the scope has
  drifted — say so and stop.

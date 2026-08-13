# CX-b6mz + CX-71m2 build brief: the ATOMIC delete-and-flip

> **The work's tickets are CX-b6mz AND CX-71m2 — one round, one commit.**
> They are not separable: there is a single dependency edge and four
> states, and **both intermediate states are unbuildable** (`apps/yelixer`
> present + git dep → Mix refuses, the umbrella source *overriding* the
> external one; `apps/yelixer` deleted + `in_umbrella:` dep → a dep with
> no app). Today→destination is unreachable by any single step. Context
> labels: CX-5kb4 was the consumability gate (landed @e30b0efb, **CONSUMABLE**);
> CX-bx59 (standalone CI) follows this.
>
> ⛔⛔ **THIS ROUND HAS NO INTERMEDIATE SAFE STATE.** Once the first
> destructive command runs there is nowhere to halt — the tree is
> unbuildable until every part is done. Its revert is clean (one commit),
> but "stop and report mid-round," which saved three rounds this week, is
> **unavailable**. ⇒ **Every stop condition in this brief is a
> PRECONDITION, evaluated BEFORE the first destructive command.** A
> conditional check placed mid-round is decoration in a round that cannot
> be paused.

## ⛔ PRECONDITIONS — all of these, before you delete or change anything

Run these first, report their values, and **halt without touching the
tree if any fails**:

1. **Tip equality.** `git ls-remote https://github.com/commonplace-systems/yelixer.git`
   must show `refs/heads/main` = **`691a4f44a91039ecc02a8824a1a5fafa79d9c253`**.
   ⛔ If it has moved, **HALT** — S37b proved *that* SHA; a moved tip
   un-proves the pin and the gate must re-run. Do not pin the new tip.
2. **The published dep resolves and compiles from scratch** — you do not
   need to redo S37b's full proof, but confirm the ref fetches.
3. **Baseline suite counts recorded** (below) so the post-change
   denominator is a comparison, not a guess.
4. **A clean tree**: nothing uncommitted that could be confused with
   this round's changes.

## What the one commit contains

⭐ **All of it, or none of it.** Enumerated because a missed item leaves
the tree broken with no safe state to stop in:

1. **`apps/commonplace/mix.exs:33`**: `{:yelixer, in_umbrella: true}` →
   ```elixir
   {:yelixer, git: "https://github.com/commonplace-systems/yelixer.git",
    ref: "691a4f44a91039ecc02a8824a1a5fafa79d9c253"}
   ```
   ⛔ **HTTPS form and this exact SHA, carried verbatim from what the
   gate proved — do not re-derive them.** CI has no SSH setup, so `git@`
   fails there; and a string the gate never exercised inherits none of
   its assurance. **Never `branch: "main"`.**
2. **Delete `apps/yelixer/` entirely.**
3. ⚠️ **`.github/workflows/ci.yml` — FOUR steps reference paths that
   will no longer exist.** I found these; verify the list is complete
   rather than trusting it:
   - `cache-dependency-path: apps/yelixer/test/fixtures/package-lock.json` (line ~29)
   - `npm ci --prefix apps/yelixer/test/fixtures` (~44)
   - `Enforce yelixer boundary` → `elixir apps/yelixer/test/support/check_commonplace_refs.exs` (~49)
   - `Run yelixer from a standalone checkout` → `bin/cp-yelixer-standalone` (~52)
4. ⭐⭐ **THE TEST-COUNT GUARD WILL TRIP, AND IT MUST BE CHANGED
   DELIBERATELY.** CI runs `bin/cp-test-guard --min 4200 --apps 6`.
   Deleting an app makes it **5 apps** and drops yelixer's **390** tests
   (measured baseline: 4,263 across 6). The guard's own comment says:
   *"do NOT lower the numbers to get green… the suite legitimately
   changed — in which case raise them deliberately, in the commit that
   changed it."* **This is the legitimate-change case, in the lowering
   direction, which is the dangerous one.** So: update `--apps` to 5 and
   `--min` to a value justified by the measured new total, **update the
   comment's measured-baseline line to say what it now is and why**, and
   state the arithmetic in the commit message. ⛔ Do not simply drop
   `--min` or the guard.
5. **`bin/cp-yelixer-standalone`**: its `SOURCE` is `apps/yelixer`, so it
   becomes meaningless. Delete it with its CI step — and see the gap
   below.

## ⚠️ The gap this round opens, which is NOT yours to close

Deleting `apps/yelixer` removes `bin/cp-yelixer-standalone` (the
self-containment guard CX-1wt1 built) and the boundary checker. **The
umbrella will no longer verify anything about yelixer** — correctly, it
no longer contains it. But the published repo has no CI of its own yet;
that is **CX-bx59**. ⇒ **Between this round and CX-bx59, nothing checks
yelixer's self-containment or its Commonplace-boundary.** State that in
the commit message so it is a known window rather than a silent
regression, and do not try to close it here.

## ⛔ Escape hatches, up front (all are PRE-conditions)

- ⛔ **If the tip has moved: HALT before touching anything.**
- ⛔ **If Mix still refuses after the delete+flip**, that is a genuine
  finding — report it. **Do NOT** add an `override:`, a `path:`, or
  vendor the library to force a green.
- ⛔ **Nothing is pushed to the yelixer repo.** No tag, no branch.
- ⛔ **Do not "improve" the deleted app's contents on the way out** — no
  final commits to `apps/yelixer`, no syncing changes upward. It is
  deleted as-is; the published repo is already authoritative.
- If the suite reveals commonplace code depending on yelixer internals
  not exported by the published library, report it — that is a real
  API-surface finding, not something to patch around locally.

## Tests

Baseline @e30b0efb: umbrella full suite **4,263 across 6 apps**
(yelixer 390, commonplace 3,215, cli 94, bots 274, mcp 156, web 134);
`apps/commonplace/test` alone **3,449 / 0 failures / 1 skipped**.
⚠️ Run per-app — multi-app `mix test` paths silently drop tests here.

- The umbrella compiles against the **pinned external dep**. ⭐ **Prove
  which source you built against** — show the resolved dep path. A green
  build is exactly what cannot tell you this, and the failure mode
  (umbrella silently overriding) is the one that started this arc.
- `apps/commonplace/test` green, count reconciled against 3,449.
- Full-suite count reconciled: 5 apps, and the new total explained
  (expect ≈ 4,263 − 390 = 3,873; say what you measure).
- ⭐ **URL-string assertions with a control**: `mix.exs` and `mix.lock`
  name `commonplace-systems`; neither names `jes5199`; the pin is a
  fixed SHA. Show the control proves `jes5199` would be found if
  present — **the stale URL resolves identically today via GitHub's
  redirect, so a working fetch cannot discriminate.**

## Review criteria

Every precondition reported with its value; one commit containing all
five items; HTTPS URL and the gate-proven SHA verbatim; the test-count
guard updated deliberately with its comment truthed and the arithmetic
stated; the CX-bx59 window named in the commit; proof of which source
the build used; counts reconciled at both scopes; nothing pushed to the
yelixer repo; no override/path/vendoring anywhere.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). bd is a
frozen archive. ⚠️ **The verb is unreachable from inside the sandbox — a
capability boundary, not a defect and not a deviation.** Report
identities; the reviewer files them.

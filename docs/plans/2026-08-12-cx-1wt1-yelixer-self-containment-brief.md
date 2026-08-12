# CX-1wt1 build brief: make `apps/yelixer` self-contained — with CX-gqj6 riding

> **The work's ticket is CX-1wt1.** ⭐ **CX-gqj6 RIDES AND CLOSES WITH IT
> — not as scope creep but because gqj6 BLOCKS THE VERIFICATION OF
> 1wt1.** `telemetry` is a runtime dependency (no `only:`), so a
> standalone checkout fails its dependency check BEFORE compiling —
> which means you cannot demonstrate the bootstrap fix works standalone
> while the lockfile is still broken. Two tickets, one verification, one
> round. Context labels, none the citation: CX-fbah is BLOCKED on this
> (DAG edge, verified) and re-runs after; CX-1mn4 was the disposition.
>
> **Why this pre-empts S36: BLOCKING-DEBT, not size or recency.** An arc
> paused on a missing precondition costs more than a fresh row deferred.
> ⛔ Do not write "it's small and it unblocks things" as the
> justification — that is a weaker and different claim.
>
> ⛔ **PLAN'S ARC-LEVEL CONSTRAINT, ratified 2026-08-12:** nothing in the
> yelixer arc that PUBLISHES, FLIPS, or DELETES (CX-b6mz, CX-bx59,
> CX-71m2) runs until the standalone's tests can start on their own.
> This round is that gate.

## The defect, and why it stayed invisible since March

`apps/yelixer/test/test_helper.exs:2`:

```elixir
Code.require_file("../../../test/support/file_rm_rf_guard.exs", __DIR__)
```

That target lives at the **umbrella root** (`test/support/`).
`apps/yelixer` has no `test/support` of its own. From the app's umbrella
position the path resolves; from a standalone checkout it escapes the
repository entirely (measured: `/tmp/test/support/… enoent`) and ExUnit
dies **before running a single test** — 0 executed, no summary.

⚠️ **This is NOT accidental drift.** All six umbrella apps use the
identical pattern; it is a deliberate umbrella-wide `rm -rf` safety
guard. yelixer is genuinely *both* an umbrella app sharing umbrella test
infrastructure *and* a standalone library, and that tension is the
defect — not a typo.

And the sibling: `apps/yelixer/mix.lock` was last touched by
`523291ab`, **the subtree import merge itself**. yelixer is the only app
carrying a lock at all, because the umbrella resolves through the ROOT
lock. It has been dead weight since March and drifted silently: `mix.exs`
declares `telemetry ~> 1.2` and the lock has zero telemetry entries.

⭐ **The shared root cause — carry it into the moduledoc/commit, it is
the durable lesson:** *being an umbrella app HID the standalone's
requirements.* The umbrella satisfies them from outside the app, so the
app's own declarations rotted invisibly because nothing ever reads them.
A subtree split is the first thing that ever audits self-containment,
and **the rot it finds always looks like new breakage.**

## What this round builds

**The property, not a mechanism** (the mechanism is yours):

1. `apps/yelixer`'s test bootstrap resolves **entirely within the app**,
   in both positions — inside the umbrella and in a standalone checkout.
2. ⛔ **The `rm -rf` guard remains ACTIVE in both positions.** This is
   the hard constraint. **A conditional skip is FORBIDDEN** —
   `File.exists?` → require, else continue — because it silently
   disables a safety guard in precisely the environment nobody watches,
   trading a loud failure for a quiet loss of protection. If your
   mechanism can produce a run where the guard is absent and the suite
   still goes green, it is the wrong mechanism.
3. `apps/yelixer`'s dependency declarations and lock agree, such that a
   fresh standalone checkout resolves deps without help (CX-gqj6). If
   the honest answer is that the app-level lock should not exist at all,
   say so with the reasoning — deleting a file that has been stale since
   March is a legitimate outcome, but it must be a decision, not a
   side effect.
4. Nothing about the other five apps changes. They are not broken; they
   are not extracted.

## ⭐ The regression guard — the round's real deliverable

Fixing the path fixes today. **It rotted for five months without anyone
noticing, and nothing prevents that recurring the day after this
lands.** So this round also leaves behind a check that goes RED when
`apps/yelixer` stops being self-contained.

- Shape is yours (a test, a mix task, a CI step). It must exercise the
  app **from outside its umbrella position** — extracting or copying the
  app tree to a temporary directory and running its suite there is the
  obvious form, and is exactly what CX-fbah's split did by accident.
- ⛔ **It must be demonstrated RED.** Break self-containment on purpose
  (reintroduce an escaping require in a scratch edit), show the check
  fails, restore. A guard nobody has seen fail is the defect it was
  written to prevent, wearing a fix's clothes.
- If the check is too slow or too fragile for the default suite, tag it
  and say where it runs — a guard that exists but never runs is prose.

## Tests (red-first; suites named with counts)

Baseline: full core **3,444 / 0 failures / 1 skipped** @53e64e82.

- ⭐ **The red-first arm must fail in the STANDALONE POSITION
  specifically** — that is the environment whose breakage stayed
  invisible since March, and a red that only reproduces inside the
  umbrella is testing the position that already worked.
- Standalone acceptance: a fresh checkout of the app tree alone resolves
  deps, compiles, and runs its suite. **Report the COUNT** — a missing
  count is not green (CX-3mj2's rule, which is what caught this defect
  in the first place).
- The umbrella's own `mix test apps/yelixer` stays green with the guard
  demonstrably still loaded — assert the guard is ACTIVE, not merely
  that tests pass without it.
- Prove any "pre-existing/unrelated" failure with an isolated rerun.

## ⛔ Escape hatches, up front

- NO push, no remote, no tag, nothing in `/home/jes/yelixer`. This round
  changes the UMBRELLA only. The standalone repo is untouched — CX-fbah
  re-runs the sync later, from a fresh split.
- ⛔ Do not resurrect the diagnostic merge `d9f8f3c0537e` or rebuild
  from it; it carries the unfixed tree.
- No dep flip (CX-b6mz), no deletion of `apps/yelixer` (CX-71m2).
- If the fix appears to require changing the shared guard for all six
  apps, STOP and report — that is a wider blast radius than this round
  owns, and today's standing lesson is that shared-seam changes get
  named by blast radius, not by the app you edited.
- Telemetry events in scope: NONE.

## Review criteria

The escaping require is gone (grep, with a control proving the pattern
is findable); the guard is provably ACTIVE in both positions and no
code path skips it silently; the regression check exists and was
**demonstrated red**; the standalone run reports a real count; deps and
lock agree or the lock's removal is argued; full core reconciled against
3,444; no change to the other five apps; nothing outside the umbrella
touched.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). bd is a
frozen archive and answers "no issue found" for everything since
2026-08-05. ⚠️ **The verb is not reachable from inside the sandbox** —
that is a capability boundary, not a defect and not something to route
around. Report finding identities in the evidence and the reviewer files
them, as happened for CX-1wt1 and CX-gqj6 themselves.

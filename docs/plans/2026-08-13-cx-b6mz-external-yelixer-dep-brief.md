# CX-b6mz build brief: flip commonplace to the external yelixer dep

> **The work's ticket is CX-b6mz.** Context labels, none the citation:
> CX-fbah published the sync (`64b2e51`, then MIT at `691a4f4`) and is
> closed; CX-1wt1 made the app self-contained; **CX-71m2 (delete
> `apps/yelixer`) is DOWNSTREAM and is now gated on S37b, a
> consumability proof — it is NOT this round and must not be
> anticipated.** CX-bx59 (standalone CI) follows that.
>
> ⛔ **PLAN'S GATE, ratified 2026-08-13:** *a gate's strength should match
> the reversibility of what it releases.* This flip is reversible — one
> line back. **The deletion is not**, which is why it sits behind its own
> proof. Do not do the deletion's work here, and do not leave the tree in
> a state that only makes sense once the deletion has happened.

## The measured ground (verify at your own read; do not inherit)

1. **Only one dependency edge exists**: `apps/commonplace/mix.exs:33`
   reads `{:yelixer, in_umbrella: true}`. Nothing else in any app's
   `mix.exs` names yelixer.
2. **The published library code is byte-identical to the umbrella's.**
   I diffed a fresh GitHub clone of `691a4f4` against `apps/yelixer`:
   `lib/` is IDENTICAL. The only differences are additive license
   metadata (LICENSE, a README section, `package()`/`description`/
   `source_url` in mix.exs). ⇒ **The flip changes where the code comes
   from, not what the code is** — so any behavioural difference after
   the flip is a packaging or resolution defect, never a code
   difference. That is a strong diagnostic: keep it in mind when
   something breaks.
3. **Published tip is `691a4f44a91039ecc02a8824a1a5fafa79d9c253`, and
   there are ZERO tags** — so a tag pin is not available today. If you
   want a tag, that is a separate act on the published repo with its own
   authority question; do not create one as a side effect.

## ⛔ THE TRAP THE TICKET NAMES, NOW MEASURED

The ticket says the URL **MUST** be `commonplace-systems/yelixer`, not
`jes5199/yelixer`. I verified why that matters, and it is worse than a
style point:

```
git ls-remote git@github.com:jes5199/yelixer.git          → 691a4f44… (rc=0)
git ls-remote git@github.com:commonplace-systems/yelixer  → 691a4f44… (rc=0)
```

**The stale URL WORKS TODAY, returning the identical SHA, because GitHub
redirects transferred repositories.** So *"does it fetch?"* — the obvious
check — **cannot distinguish a correct URL from a stale one.** The
redirect is not a guarantee: it disappears if anyone ever creates
`jes5199/yelixer` again, and then a build that has worked for months
fails or, worse, silently resolves to someone else's repository.

⇒ **The check must be on the URL STRING in `mix.exs` and `mix.lock`, not
on whether the fetch succeeds.** A green build is not evidence here.
This is the same family as everything else this week: evidence that
cannot discriminate.

## ⭐ The round's first question — answer it before building

An umbrella auto-discovers `apps/*` as in-umbrella applications. **So
`apps/yelixer` existing AND a git dependency named `:yelixer` may be a
conflict Mix refuses** (two sources for one app). If so, the flip as
literally specified is not expressible while `apps/yelixer` remains —
and **the deletion is gated behind S37b, so you may NOT simply delete
it.**

**Determine this by experiment, not by reasoning, and report what you
found.** If they cannot coexist:

- ⛔ **STOP AND REPORT.** Do not delete `apps/yelixer`, do not move it
  out of `apps/`, do not merge this round into the deletion. Plan
  ordered these separately on purpose and the ordering is a safety
  property, not bookkeeping.
- Say precisely what Mix does (the error, the mechanism), because that
  determines whether the arc needs a re-plan or a different flip shape.

If they *can* coexist, continue below.

## What the flip is

- `{:yelixer, in_umbrella: true}` becomes a git dependency on
  **`commonplace-systems/yelixer`**, pinned to a **LOCKED SHA**
  (`691a4f44a91039ecc02a8824a1a5fafa79d9c253` unless you have a reason
  to pin elsewhere — say the reason). ⛔ **Never `branch: "main"`, never
  floating.** CI must build the same bytes tomorrow as today.
- **A path-override dev loop** so local yelixer work is still possible
  without a push-per-edit cycle. Mix supports overriding a dep to a
  local path via `:path` in config or the `MIX_DEP_OVERRIDE`-style
  arrangement the project prefers — pick a mechanism, **document it in
  the repo where a developer will look** (not only in the commit
  message), and state its failure mode: an override left enabled means
  CI-green code that never built against the pinned dep.
- The lock must record the pinned SHA and the correct URL. Check both.

## ⛔ Escape hatches, up front

- **Nothing is deleted this round** — not `apps/yelixer`, not its tests,
  not its CI steps. If the flip seems to require deletion, STOP (above).
- **No pushes to the yelixer repo**, no tags, no branches there. That
  repo is published and this round only consumes it.
- If the pinned SHA does not compile inside the umbrella, that is a
  finding about the published artifact — report it; do not patch around
  it locally, and do not repoint to a different ref to make it pass.
- Do not touch `bin/cp-yelixer-standalone` or its CI step; the
  self-containment guard stays exactly as it is.
- Telemetry, storage, MUD, web: untouched.

## Tests (suites named with counts)

Baseline: full core **3,449 / 0 failures / 1 skipped** @4c1a61c1.
⚠️ Run per-app — multi-app `mix test` paths silently drop tests here.

- The umbrella compiles and the full core suite is green **against the
  pinned dependency**, not against the in-umbrella app. ⭐ **Prove which
  one you built against** — that is the round's central claim and it is
  exactly the thing a green build does not tell you. State how you
  proved it (dep path, build artefact location, or a deliberate
  perturbation of the dep that must show up).
- ⭐ **URL-string assertions, since fetch success cannot discriminate**:
  `mix.exs` and `mix.lock` both name `commonplace-systems`, and neither
  names `jes5199`. Include a control showing the grep would find
  `jes5199` if present.
- The pin is a fixed SHA — assert no `branch:`/floating ref.
- `bin/cp-yelixer-standalone` still passes (it is independent of this
  flip; if it breaks, that is a finding).

## Review criteria

The URL is `commonplace-systems` in both mix.exs and mix.lock with a
findable-pattern control; the pin is a locked SHA with no floating ref;
the dev-loop override is documented where a developer will look, with
its failure mode stated; the suite is proven to have built against the
pinned dep rather than the local app; **nothing deleted and nothing
moved**; the coexistence question answered by experiment and reported
either way; full core reconciled against 3,449 with per-app runs.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). bd is a
frozen archive. ⚠️ **The verb is not reachable from inside the sandbox —
a capability boundary, not a defect and not a deviation.** Report
finding identities in the evidence and the reviewer files them.

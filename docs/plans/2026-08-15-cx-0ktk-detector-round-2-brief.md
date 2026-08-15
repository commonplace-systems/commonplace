# CX-0ktk round 2: make the detector count-neutral, make it report ALL, then watch content

> **Tickets: `CX-0ktk` (the leak) and `CX-721q` (the instrument's correctness).**
> Base: **the commit that adds this brief** — ⚠️ *not a sha.*
> **Prior round's detector: `4d931bb0` on `sol/cx-0ktk-leak-detector-s74`.**

## ⛔⛔ THIS ROUND HAS A DECLARED EXPIRY. A NULL IS A PUBLISHABLE RESULT.

```
names the leaker  →  it gets fixed, and the identity slice's I3 merges
does NOT          →  CX-0ktk is reported NOT REACHABLE THIS WAY, I3 merges,
                     and the reproducer dies (measured: +3 tests already killed it once)
```
⭐ **So a clean result is a DECISION-QUALITY ANSWER, not a failure.** ⛔ **Do NOT
reach for a sixth theory to avoid reporting a null.** ⚠️ **And there is no
extension for a PROMISING PARTIAL — *a partial result that feels close is exactly
what makes a hold renew itself.*** **Report what you measured.**

## The three parts, and they are ONE round

**`①` and `②` are not scope creep — they are the conditions under which `③` is a
measurement rather than an anecdote.** *Granting only `③` would buy a round that
can succeed and produce nothing anyone may quote.*

### ⛔⛔ ① COUNT-NEUTRAL, OR THE INSTRUMENT IS BLIND

**Measured today, one variable, and this is the whole reason the round exists:**
```
detector + its control file    3511 tests  0 failures  victim GREEN  ← BLIND
detector, control NOT loaded   3510 tests  1 FAILURE   victim FAILS  ← sees it
```
⇒ ⭐⭐ **plan's ruled requirement: *A DETECTOR THAT CHANGES THE POPULATION IS PART
OF THE POPULATION.* The hook must add ZERO test cases — `3510` with it and `3510`
without.**
⚠️⚠️ **`@tag`-EXCLUDING IS NOT ENOUGH. The file is STILL LOADED AND STILL
COUNTED** — *excluded moved `12 → 13` and that one file flipped the victim green.*
⇒ **The positive control must live OUTSIDE the default run** (its own path, or
loaded under an env gate) **and still be runnable on demand to prove liveness.**
⛔ **ASSERT THE COUNT IN YOUR REPORT: `3510` with the hook installed.** *The
formatter and `max_cases: 1` are free — the `--trace` run reproduced at 3510 with
`max_cases: 1` — so do not remove those to chase neutrality.*

### ⛔⛔ ② REPORT ALL DIVERGENCES — `CX-721q`, and it GATES CITATION

**The detector currently records only `first_leak`** (grep
`record_first_divergence`). ⇒ ⛔ **THREE RUNS HAVE PRODUCED TWO DIFFERENT "FIRST"
LEAKERS** (`Store.SnapshotReimportTest`, `DeniedWriteReportingTest`). ⇒ ⭐⭐
***"The detector named X" is a statement about ORDERING, not about X's
significance.*** **Multiple leaks exist; first-only shows whichever the deck put
first.**

⛔ **PLAN'S GATE, IN FORCE UNTIL THIS LANDS: NO FINDING MAY CITE "the detector
named X" AS IDENTIFYING ANYTHING.** ⭐ *Report-all is "the difference between an
instrument and a coin flip with a log."*
⇒ **Report every divergence with the test that caused it and the keys that
changed.** ⚠️ **This also frees the positive control from having to be excluded
to avoid masking real leaks — the `CX-q9sa` convention in `test_helper.exs`
(controls stay ON as proof-of-life) then applies again.**

### ⭐ ③ WATCH THE ARTIFACT'S CONTENT, NOT JUST ITS EXISTENCE

**The watched set covers `:data_dir`, `:trust`, `:local_write_gate`, and the
EXISTENCE + RESOLVED PATH of `node_signing_public_keys.json` — but NOT its
CONTENT.** ⇒ ⛔ ***"The file is there" is a property a WRONG FILE also
satisfies.*** **Two runs can both have it and differ in WHICH KEY is in it.**
⇒ **Add a content hash.** ⭐ *Same class as a `@cid` present in a ref not proving
the pin is enforced.*

## ⛔ NEVER SUBSET

**Four elimination methods were refuted before this approach was chosen, because
every way of looking at a subset IS a perturbation of the ordering under test
(plan's law `7n3`).** ⇒ ⛔ **If you find yourself deleting, slicing or re-seeding
the population, STOP AND REPORT.** ⭐ **Observe without intervening, or accept
you are measuring your own intervention.**

## ⚠️ Facts already measured — do NOT re-derive, and do NOT re-test these

- **Survives `--trace` / `max_cases: 1`** ⇒ **SEQUENTIAL contamination, not
  concurrency.** ⛔ *`CX-5gkw`'s load/time-budget playbook does not apply.*
- **Survives `tmp/test_data` being stashed away entirely** ⇒ **not disk state,
  not `CX-hzad`'s family.**
- **Ordering is NOT the discriminator:** `seed 117514` RED has leaker `#43` →
  victim `#136`; `seed 1` GREEN has leaker `#46` → victim `#205`. **The leaker
  runs BEFORE the victim in BOTH.**
- **Refuted hypotheses (five, all the reviewer's):** absent-artifact ·
  `RestoreTest`-adjacency · prefix-position · leftover `tmp/test_data` ·
  present-artifact. ⭐ *Each died to one cheap command. Being wrong cheaply is the
  method working.*
- **The actual assertion:** `assert out =~ "Owner's Den"` gets
  `"(this place has no description)"` — grep `self-read` in
  `room_visibility_test.exs`. **Unwritten doc vs gated read: STILL UNKNOWN.**

## ⛔ RUN IT ALONE ON THE BOX

**In those words, and say so in your report.** *`CX-5gkw`: load-induced
time-budget crossings are this suite's flake mechanism, so a shared run measures
LOAD, not ORDER.* ⚠️ ***"When convenient" and "alone" are indistinguishable
afterwards.***

## ⚠️ THE SANDBOX CANNOT SIGN

**`node_signing_key` is MASKED in your fence** ⇒ `NodeIdentity.signing_context/0`
fails and no node-signed write succeeds. **Use the injectable
`opts[:signing_context]` seam** (`Bursar`, `Frontier.Server`, the identity rounds).
⚠️ **A full suite DOES run in a worktree despite the baseline block saying "no
repo `deps/`" — S71 ran 3506 tests inside one.**

## Suites

⛔ **Run `bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK.**
```
seed 117514  3510, 1 FAILURE  ← CX-0ktk, the thing you are here for. EXPECTED.
seed 1       3510, 0 failures
seed 424242  3510, 0 failures
```
⚠️ **`cp-suite-baseline` DEFAULTS to `117514`.** ⛔ **If your count is not `3510`
with the hook installed, part `①` is not done — that is the check, not a
formality.** ⚠️ **`CX-s9kc`: sandbox `chat_view_compute_supervisor_test.exs`
flake, non-deterministic, NOT yours.** ⛔ **Anything else IS yours.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`.*
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⚠️ ***Its author is 0-for-5
  on this bug today, and the previous round's best contribution was correcting
  this brief's ancestor rather than satisfying it*** — *it caught that "never
  perturbing" was overstated.* ⛔ **If any of `①②③` is wrong, saying so is worth
  more than the round.**
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to narrow by subsetting,
  to name a leaker before report-all lands, or to call a promising partial a
  result.
- ⭐⭐ **WHAT WAS THIS COPIED FROM, AND WHAT HAS BEEN COPIED FROM THIS?**

## Review criteria

Count asserted at exactly `3510` with the hook installed; the control runnable on
demand but outside the default population; ALL divergences reported with their
tests and changed keys; a content hash in the watched set; no subsetting; the
victim's status reported SEPARATELY from the detector's findings; the box stated
to have been exclusive; and a null reported as a null if that is what the run
produced.

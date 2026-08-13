# The integrity probe must report its COVERAGE — CX-rvbr (rider, lands first)

> **The work's ticket is CX-rvbr.** ⛔ **This round does NOT fix the
> probe's method or its budget.** Those are the open design question and
> they are genuinely hard — the measured distribution removed both
> obvious approaches. **This round makes the existing degradation
> VISIBLE**, which is correct whatever the method later becomes, and
> ships now rather than waiting behind a hard problem.

## What is wrong, measured

`CommitStore.probe_integrity/1` (commit_store.ex:3315) runs
`CubDB.select() |> Enum.each(...)` under a **5,000 ms** budget. On
timeout it logs *"exceeded 5000ms (partial scan) — treating store as
healthy"* and **returns `:ok`**.

Measured on a `CubDB.back_up/2` copy of the live store, unloaded host,
no serve contention:

| | |
|---|---|
| entries | **150,779** |
| on disk | **4.0 GB** |
| decoded value bytes | **1,368,835,248** |
| the probe's exact operation | **13,862 ms** — **2.8× its budget** |

⇒ **It cannot complete and never could.** It is **byte-bound, not
entry-bound**: 150,779 entries is modest, 1.37 GB of decoded CRDT
payload is not. The probe's own comment carries the assumption that hid
this — *"no deserialization beyond what `CubDB.select` already forces"*
— and `select` forces the whole value.

⭐⭐ **THE FAILURE MODE, which is why this rider matters on its own: a
time-bounded scan that reports healthy on timeout STOPS CHECKING WHILE
CONTINUING TO PASS.** Today it walks roughly a third. At 12 GB it walks
a ninth. **At every coverage level, including zero, the reported result
is identical.** Coverage trends monotonically toward zero as the store
grows, so the check **becomes vacuous on a schedule set by success** —
and nothing in its output would ever say so.

## What to build

**Make the probe report what it actually covered**, in a form where the
degradation is legible over time.

⛔ **AND THE OBVIOUS FORM IS NOT AVAILABLE — do not attempt it.**
"scanned N of M (x%)" needs a total, and **`CubDB.size/1` is
`Reader.size(btree)` = `Enum.count(btree)`, a FULL TRAVERSAL** — the
exact cost the probe cannot afford. ⇒ **Computing the denominator would
double the problem the number exists to describe.**

⭐ **So report what is cheaply knowable and be honest that the rest is
not:**

- **entries actually walked** (a counter through the `Enum.each` — the
  probe currently counts nothing);
- **bytes walked**, if it can be accumulated without a second pass, since
  the cost is byte-bound and entries alone understate it;
- **elapsed vs budget**;
- **whether the scan COMPLETED or was cut short**;
- ⚠️ **and, when cut short, that the covered FRACTION IS UNKNOWN** —
  the number is a **lower bound on work done**, not a percentage of the
  store. **Say that in the message rather than leaving a bare count to
  be read as completeness.**

⭐ **The message must degrade legibly**: a bare "scanned N" is a number
nobody diffs. Something a reader can compare month to month — walked
count, bytes, elapsed, and the explicit "coverage unknown, partial" —
is what makes the next person notice. **The whole point is that
someone notices next time.**

**A completed scan should say so too**, with its count and elapsed:
"completed, N entries in Xms" is what makes a later partial visibly
different rather than merely differently-worded.

## ⛔ Escape hatches, up front

- ⛔ **Do not change the budget, the method, or the availability
  decision.** Returning `:ok` on timeout is deliberate (availability
  over paranoia) and stays. If you believe it is wrong, that is a
  finding to report — not this round's change.
- ⛔ **Do not add a full-traversal count** to produce a denominator.
  See above: it costs what the probe cannot afford.
- If accumulating bytes requires a second pass or a deserialization the
  probe does not already do, **report that and omit it** — entries plus
  elapsed plus the honest unknown is sufficient.
- Telemetry events: NONE required, but if you emit one, it carries the
  same fields as the log line.

## Tests

Baseline: full core **3,456 / 0 failures / 1 skipped** @dfa6fd99.
⚠️ Run per-app — multi-app `mix test` paths silently drop tests here.

- ⭐ **Both arms observed**: a probe that COMPLETES reports completion
  with its count; a probe that is CUT SHORT reports partial **and says
  the fraction is unknown**. A test that only exercises the completing
  path proves nothing about the message that matters.
- Force the timeout deterministically — a tiny configured budget on a
  fixture store is fine; **do not rely on a large store or on load.**
  (Tonight's lesson: a budget sized around an undiagnosed slowness is
  how this class hides.)
- Assert on the message's CONTENT — the count, and the explicit
  unknown-fraction statement — not merely that a warning was emitted.

## Review criteria

Both arms observed and asserted; the partial message states the fraction
is unknown rather than implying completeness; no full traversal added;
budget/method/availability behaviour unchanged; the log line is
comparable over time rather than a bare number; counts reconciled
per-app against 3,456.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). ⚠️ Not
reachable from inside the sandbox — a capability boundary, not a defect.
Report identities; the reviewer files them.

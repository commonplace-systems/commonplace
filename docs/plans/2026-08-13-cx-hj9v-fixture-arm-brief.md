# CX-hj9v build brief: the REAL-FIXTURE arm must fail loudly, and its data must travel

> **The work's ticket is CX-hj9v** (open, p1, filed 2026-08-13).
> ⚠️⚠️ **THIS ROUND IS IN A DIFFERENT REPOSITORY: the standalone
> `commonplace-systems/yelixer` at `/home/jes/yelixer`, NOT the
> commonplace umbrella.** The umbrella consumes yelixer as a **pinned git
> dep** (`691a4f44…`), so **the pin moves AFTER this lands, never
> before** — and that pin move is the reviewer's, not this round's.

## The defect, measured

`test/cx_mchn_delete_set_repro_test.exs:218` — the **REAL FIXTURE** arm:

```elixir
fixture =
  Path.join([__DIR__, "..", "..", "commonplace", "test", "fixtures",
             "cx_k20z_start_meta_precorruption.bin"]) |> Path.expand()

if File.exists?(fixture) do
  ...
end
```

⇒ **The path encodes the OLD UMBRELLA LAYOUT.** From
`apps/yelixer/test/`, `../../commonplace/test/fixtures/` resolved
correctly. From the standalone's `test/`, it resolves to a **sibling of
the repo** that does not exist. **Measured 2026-08-13: the arm printed
`Fixture not found at … — skipping fixture-based repro` and the file
reported `6 tests, 0 failures`.**

⭐⭐ **A TEST THAT SILENTLY DEGRADES TO A NO-OP WHEN ITS INPUT IS ABSENT
IS A CHECK THAT CANNOT FAIL** — and this is the worst arm for it to
happen to: **it is the only one testing the CX-mchn mixed-plane defect
against data that ACTUALLY CORRUPTED**, rather than against a
constructed repro. ⇒ **It is the difference between "fixed" and "fixed
and would notice if it came back."**

⚠️ **Root cause is structural, not a typo**: the yelixer extraction moved
the TEST and left the FIXTURE behind in commonplace at
`apps/commonplace/test/fixtures/cx_k20z_start_meta_precorruption.bin`
(committed `037cd18c`). **An extraction relocates evidence and nothing
follows it.**

## ⛔ The ruled fix — BOTH halves, not either

| half | what it is | why alone is insufficient |
|---|---|---|
| **the arm FAILS LOUDLY when the fixture is absent** | the **guard** | a travelling fixture with a silent skip **re-arms the same defect** the next time a path moves |
| **the fixture TRAVELS into yelixer** | the **repair** | a loud failure with no fixture is a **permanently red suite** |

- ⭐ **Put the fixture where the test can find it without encoding a
  layout** — inside yelixer's own `test/` tree, addressed relative to
  `__DIR__` with no `..` escaping the repo. ⛔ **A path that leaves the
  repository is the defect, not the spelling.**
- **The binary is ~the artifact itself** — copy it byte-identical from
  the umbrella and **verify by checksum both sides**, reported.
- ⛔ **Do not change what the arm ASSERTS.** Its subject is the CX-mchn
  mixed-plane defect and it currently passes on real data when it runs;
  this round changes **where the data lives and what happens when it is
  missing**, nothing else.

## ⭐ Acceptance: demonstrated BOTH WAYS

- **Fixture present** → the arm **RUNS** and asserts on the real sample.
  ⚠️ **Its diagnostic output must appear** (`=== CX-mchn fixture repro
  ===` and the content prefix) — *that output is how a reader knows it
  ran at all.*
- ⭐⭐ **Fixture deliberately removed → the suite goes RED naming the
  missing fixture.** ⛔ **Demonstrate this by revert-control and report
  both outputs.** ⚠️ *An arm that has never been seen to fail on a
  missing fixture is exactly the state being repaired — a green here
  proves nothing without its red.*
- **Report the file's own count from the tree**, before and after.

## ⚠️ Repo-specific hazards — read before running anything

- ⛔ **yelixer has NO `mix.lock`, DELIBERATELY** (CX-1wt1
  self-containment; CI asserts its absence). Running `mix deps.get`
  **creates one.** ⇒ **Do the dependency fetch in a scratch COPY, or
  ensure `mix.lock` is NOT part of your delivered diff.** ⛔ **A
  `mix.lock` in the diff fails the round.**
- ⚠️ **CI carries a count-asserted suite** (`bin/yx-test-guard --min
  380`) **and a Yjs conformance matrix** (stable + preview, **exactly
  11/0 each**). ⇒ **If your change moves the test count, say so and say
  by how much**; whether the `--min` moves is a reviewer decision.
  ⛔ **Do not weaken either guard to make your change fit** — if
  something must move, **report it and stop.**
- ⭐ **The conformance matrix must stay green.** You are not touching
  encoding, so it should be untouched — **but report it, because
  "should be" is not a measurement.**
- ⛔ **Never a commit; `.git` is read-only.** ⛔⛔ **AND NEVER PUSH TO
  YELIXER — jes's standing ruling forbids force-push there entirely, and
  this round pushes nothing at all.** Produce the **intended commit
  message**; the reviewer lands it.

## Files

- **MAY touch** (in `/home/jes/yelixer`):
  `test/cx_mchn_delete_set_repro_test.exs` · a new fixture file under
  `test/`.
- ⛔ **MUST NOT touch**: `lib/**` (no library change is required — if
  you believe one is, **STOP AND REPORT**) · `.github/workflows/ci.yml` ·
  `bin/yx-test-guard` · anything in the commonplace umbrella.

## ⛔ Standing discipline

- ⛔ **If you cannot find this brief, STOP AND SAY SO.**
- ⛔ **Do not run `mix format` or `mix precommit`.**
- ⛔ **If a fenced capability is needed, NAME IT** — the sandbox has no
  `~/.ssh`, an allowlisted env, masked sockets. **A `0` from a probe may
  mean MASKED, not ABSENT.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** If a stated fact —
  the line number, the path expression, the measured skip — does not
  match the artifact, ⛔ **report the discrepancy rather than satisfying
  the claim.**
- ⭐ **Report the NEAR-MISS**, including anything that tempted you to
  widen the arm's assertions or to touch `lib/`.
- ⭐ **Report a MEASUREMENT, never a mechanism you did not observe.**

## Review criteria

The arm runs with the fixture and its diagnostic output is visible; the
suite goes RED, naming the fixture, when it is removed — **demonstrated,
with both outputs**; the fixture is byte-identical by checksum on both
sides; no path escapes the repository; no `mix.lock` in the diff; no
`lib/` change; conformance matrix reported; counts reported from the
tree.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). ⚠️ Not
reachable from inside the sandbox — **a capability boundary, not a
defect.** Report identities; the reviewer files them.

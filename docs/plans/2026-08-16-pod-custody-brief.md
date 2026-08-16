# Custody: the pod holds ITS OWN key and NOT the durable one — proven by value

> **Ruled by `commonplace-plan`.** Base: **the commit that adds this brief** —
> ⚠️ *not a sha.* **Build the worktree from that base.**
>
> ⭐ **If this lands, the joining arc has no remaining claim without code.**

## Why this is ONE round and not two

**Four consecutive rounds have correctly declared custody out of scope. It is now
the subject.**

⛔⛔ **CUSTODY IS ONE PROPERTY: *"holds ITS OWN key, and NOT the durable one."***
⇒ ***Splitting it ships HALF A PROPERTY TWICE, and the first half reads as the
whole.***

⚠️ **The absence half could not ride earlier and must not be deferred later:**
⇒ ⛔ ***"No cell key in the pod" WOULD PASS ON A POD THAT HOLDS NO KEYS AT ALL
AND NEVER SIGNED ANYTHING.*** **Before presence it is VACUOUS; after presence it
is FREE.**
⭐ *One-unknown-per-rung is about UNKNOWNS, not assertion count. This round's
unknown is CAN A POD MINT AND USE ITS OWN KEY. The absence check adds no unknown
— it is an inspection whose meaningfulness this round itself creates.*

## ⛔ Measured on the current tree — re-derive anything you rely on

```
Provisioner builds masks AS DATA:
    %{name: :node_signing_key, operation: :ro_bind_null, path: <data_dir>/node_signing_key}
    %{name: :secrets,          operation: :tmpfs,        path: <data_dir>/secrets}

Launcher RUNS them: Provisioner.provision → open_pod → Port.open({:spawn_executable, …})
    /usr/bin/bwrap present; NO skip guards in the launcher tests.

What is TESTED about the masking today — provisioner_test.exs:
    assert Enum.map(spec.masks, & &1.name) == [:node_signing_key, :secrets, …]

Minting or signing INSIDE a pod:  NONE. deployment_record.ex signs, but
    launcher-side, from an `opts[:signing_context]` handed to it.
```

⇒ ⭐⭐⭐ **THE MASKING IS ASSERTED AS A LIST OF NAMES ON A SPEC. NOTHING PROVES A
RUNNING POD CANNOT READ THE KEY.** ⛔ ***That is SHAPE, not EFFECT — a name
asserted, a state unproven.*** ⚠️ **Exactly the defect that made ceremony arm 10
pass for its whole life while testing nothing.**
⭐ **The by-effect pattern already exists here and you should follow it:**
`"pod cannot read a canary injected by its launching BEAM"` **`await_file`s a
file THE POD WROTE.** ⇒ *Execution proven by effect, not by exit code.*

## ⛔ What to build

**A pod MINTS its own signing key inside its `secrets` tmpfs, SIGNS something
with it, and the durable key is proven absent BY EFFECT — from inside the pod.**

### ⛔⛔ THE ABSENCE ARM MUST BE A COMPARISON BY VALUE, NOT TWO LOOKUPS

⇒ ***ASSERT THAT THE KEY THE POD HOLDS IS NOT THE CELL/DURABLE KEY — by value.***
⛔ **"An ephemeral key is present" and "the durable key is absent" CAN BOTH PASS
WHILE A BROKEN LOOKUP RETURNS NOTHING FOR EVERYTHING.**
⭐ **This is the arms-must-differ rule arriving at custody** — the same shape as
`assert no_record != empty_lookup` two rounds ago, and the same shape as three
instrument failures in one night that each returned a uniform negative.

## ⛔ Acceptance — artifacts

1. ⭐⭐ **The pod MINTS a key inside its own `secrets` tmpfs and SIGNS with it,
   proven BY EFFECT** — the signature (or something only the holder could
   produce) comes back out of the pod, as the canary test does with a written
   file. ⛔ *Not "the spec says tmpfs". Not an exit code.*
2. ⭐⭐⭐ **THE COMPARISON: the key material the pod holds is asserted DIFFERENT
   BY VALUE from the durable key.** ⛔ **A test where both a presence check and
   an absence check pass, but nothing compares them, DOES NOT SATISFY THIS.**
3. ⭐ **The durable key is unreadable FROM INSIDE THE POD, demonstrated by
   effect** — the pod reports what it found, and it is not the key.
   ⚠️ **The pod must report a DISTINGUISHABLE result for "masked" versus "I could
   not run the check at all".** ⛔ ***An empty answer and a proven absence are the
   same string to a careless assertion*** — this repo's own launcher canary
   refuses to treat `""` as `"absent"`, and this arm must be at least as strict.
4. ⭐ **RED FIRST: show that TODAY nothing mints inside a pod**, verbatim, **and
   that the masking is asserted only as spec NAMES** — then show both changed.
5. **Existing launcher and provisioner tests still pass**, and the environment
   canary is NOT loosened.
6. **PER-FILE counts AND the suite total from the tool's own block, plus the
   POPULATION DELTA BY HAND.**

## ⚠️ IF THE SANDBOX CANNOT RUN A POD

⭐ **Say so and STOP on that arm — `UNVERIFIED`.** ⛔ **Do NOT simulate a pod, and
do NOT report a measurement you could not have taken.** ⚠️ *Nested bwrap may not
work inside your sandbox even though `/usr/bin/bwrap` exists on the host; that is
a legitimate finding and a publishable result.*
⭐ **If pods cannot run in there, the round's honest output is: the RED-FIRST
measurements, the code, and a clear statement of which arms are OWED on a host.**

## ⚠️ THE SANDBOX CANNOT SIGN AS THE NODE

**`node_signing_key` is MASKED — which is THIS MECHANISM applied to your own
sandbox** ⇒ `Commonplace.Crypto.NodeIdentity.signing_context/0` fails. ⭐ **Use
fixture signing contexts via `opts[:signing_context]`.** ⚠️ *That masking is the
subject of this round, so do not "fix" it to make an arm reachable.*

## Suites

⛔ **`bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK.** **Baseline
pasted verbatim as measured:**
```
  5 doctests, 3533 tests, 0 failures, 12 excluded, 1 skipped  (seed 117514, rc=0)
  --- state the run STARTED in … [stamp-v2] ---
  sha:        d2ac5c12 (DIRTY — 3 tracked file(s) under apps/ or config/ modified vs HEAD)
  test state: DIRTY — tmp/test_data/root present (written 2026-04-27)
  deps:       repo deps/   cwd: /home/jes/commonplace/apps/commonplace
```
⚠️ **That run's dirt was `CX-kacr`, since landed as `0ebabea9`; `3533` is the
correct expectation for your base.** ⭐ **`[stamp-v2]` sees untracked test files.**
⚠️⚠️ **THE LEAK DETECTOR'S OBSERVED VALUES ARE A RECORD, NOT A BOUND** — seen
`0 · 58 · 68 · 72 · 115 · 117 · 118 · 120 · 122 · 123 · 126 · 127 · 135 · 141 ·
149 · 152`. ⛔ **A value outside it is NOT an anomaly and NOT a finding. Only
`FAILURE` rather than `ADVISORY` is.**

### ⚠️ Known-nondeterministic, by TEST and MECHANISM — NOT yours

```
GitBridge.ServerTest — "GenServer.stop → no process" teardown check-then-act.
  THREE distinct tests, reproduced ON A CLEAN TREE. Known BY MECHANISM.
  ⛔ Any OTHER error shape in that module is YOURS.
Runner.LauncherTest — "pod cannot read a canary injected by its launching BEAM".
  Environment-sensitive; `canary_result == ""` where "absent" is expected. Passes
  in isolation. ⛔ A DIFFERENT error shape there is YOURS.
```
⚠️ **`CX-7rjn` is FIXED at `2e693cd6` — a `DeniedWriteReportingTest` failure now
is NEW and is yours.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`
  — workspace-relative, NOT repo-root, NOT `data/`.*
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.**
- ⛔⛔ **DO NOT SELECT PROCESSES BY NAME OR ARGV PATTERN.** *This repo's launcher
  already forbids it with a positive control, and the brief's author violated it
  four hours ago and killed their own shell. Kill and wait by CAPTURED PID.*
- ⭐⭐ **REDIRECT TEST OUTPUT TO A FILE AND GREP THE FILE.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES.**
  ⭐ *The previous round's premise — "the launcher never runs the pod" — was FALSE
  and was caught before it burned a round. Check this one too.*
- ⭐ **VERIFY BY RE-READ, not by the write returning.**
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to satisfy the absence
  arm with a spec assertion, or to let "masked" and "check did not run" share a
  result.
- ⭐⭐ **WHAT WAS THIS COPIED FROM, AND WHAT HAS BEEN COPIED FROM THIS?**

## Review criteria

A pod minting its own key in its `secrets` tmpfs and signing with it, proven by
effect; the durable key unreadable from inside, proven by effect and
distinguishable from a check that did not run; the key the pod holds asserted
DIFFERENT BY VALUE from the durable key; the red-first artifact showing today's
spec-only masking assertion and the absence of any in-pod minting; existing
launcher and provisioner tests green with the canary unloosened; per-file counts,
the suite total, and the population delta by hand.

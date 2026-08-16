# The launcher declares its scope, or refuses at birth naming the missing field

> **Ruled by `commonplace-plan` — `CX-kacr`, whose CONDITION HAS FIRED.** Base:
> **the commit that adds this brief** — ⚠️ *not a sha.*
>
> ⛔ **This must land BEFORE any round touching the launcher's placement or
> deployment.** *It was filed as a CONDITION rather than a queue position
> precisely so that nobody would have to remember it: the work walked into it.*

## The property, and what protects it today

**`launcher.ex` states, as a requirement:**

> *"It must be started in a dedicated runner service whose systemd scope contains
> no live workspace serve, shell, or trading process… The launcher is
> deliberately not installed in `Commonplace.Application`, because that is the
> live-workspace serve."*

**The reason is blast radius: with `OOMPolicy=stop`, memory pressure can stop the
pod fleet AND its launcher without touching an unrelated scope. A launcher inside
the live-workspace serve means an OOM takes the serve down with the pods.**

**Measured on the current tree, with controls:**
```
"dedicated runner service" in launcher.ex        1   ← the claim exists
any declaration/scope check in launcher.ex       0   ← nothing enforces it
   (control: 3 lifecycle hits in the same file, so the file was read)
Runner.Launcher in application.ex                0   ← correctly not installed
   (control: 35 'children' refs in that file, so the file was read)
```
⇒ ⛔ **NOTHING ENFORCES IT. A launcher started inside the serve works fine until
the day it matters — and THE DAY IT MATTERS IS THE FIRST OOM,** which is exactly
when you least want to discover it.

⭐ **`CX-vvbh`'s law: a docstring stating a property the code does not enforce
must either become ENFORCED or become ACCURATE.** ⇒ **Here it must become
enforced, because the accurate version — *"we hope"* — is worthless.**

## ⛔⛔ THE MECHANISM CHOICE IS THE WHOLE VALUE

**ASSERT A POSITIVE MARKER. DO NOT SCAN FOR THE ABSENCE OF A SERVE.**

⚠️ **The tempting form is: at boot, refuse if a live workspace serve is in this
scope.** ⛔ ***That has an ordering hole and it is the oldest one we have:
ABSENCE AT BOOT DOES NOT MEAN ABSENCE.*** **The serve may start AFTER the
launcher, and a snapshot of an absence cannot distinguish "not there" from "not
there YET."**

⇒ ⭐⭐⭐ **THE LAUNCHER REQUIRES A MANDATORY DECLARATION that this scope is the
dedicated runner service, AND REFUSES AT BIRTH NAMING THE MISSING FIELD when it
is absent.**

⇒ ⭐⭐ ***A MISSING MANDATORY VALUE PROVES A WRONG REFERENT IMMEDIATELY AND
UNCONDITIONALLY. A PRESENT FORBIDDEN VALUE ONLY PROVES A PROBLEM ONCE IT HAS
ARRIVED.***

⚠️ **This same choice has been made three times in the last day and was correct
each time — an opts ALLOWLIST, a POSITIVE provenance marker, a PROCESS filter.**
⇒ ⛔ ***DEFINE WHAT IS ADMITTED BY CONSTRUCTION; NEVER ENUMERATE WHAT IS
EXCLUDED.***

## ⛔ Acceptance — artifacts

1. **The launcher REFUSES TO START without the declaration, and the refusal
   NAMES THE MISSING FIELD** rather than failing generically.
2. ⭐⭐ **POSITIVE CONTROL THAT ATTEMPTS THE FORBIDDEN ACT: start the launcher in
   a scope carrying NO runner declaration — ⭐ THE SERVE'S OWN CONFIG IS THE
   NATURAL FIXTURE — and it must refuse.** ⛔ ***A fixture that merely omits the
   marker in a bare test env is MANUFACTURED; the serve's real config is the one
   that would actually happen.***
3. **The quiet half: a correctly-declared runner service STILL STARTS, and the
   existing launcher tests still pass.**
4. ⭐ **PRINT BOTH OUTCOMES AND SHOW THEY DIFFER.** ⛔ *If the declared and
   undeclared cases produce the same observable, the check did not run.*
5. **PER-FILE counts AND the suite total from the tool's own block, plus the
   POPULATION DELTA BY HAND.**

## ⚠️ A TEST IN THIS AREA IS ENVIRONMENT-SENSITIVE — do not "fix" it

**`Runner.LauncherTest` — *"pod cannot read a canary injected by its launching
BEAM"* — is a KNOWN environment-sensitive red (`CX-kacr`'s own evidence; a stray
tmux socket has triggered it). It fails as `canary_result == ""` where `"absent"`
is expected.**
⇒ ⭐⭐ **THAT TEST IS DOING SOMETHING RIGHT AND MUST NOT BE LOOSENED: IT REFUSES
TO TREAT `""` AS `"absent"`.** ***An empty probe result and a genuine absence are
the same string to a careless assertion; it distinguishes them, which is why it
goes RED instead of quietly passing.*** ⛔ **The pressure to relax it will arrive
dressed as noise reduction. Refuse it and say so.**

## ⚠️ THE SANDBOX CANNOT SIGN

**`node_signing_key` is MASKED** ⇒
`Commonplace.Crypto.NodeIdentity.signing_context/0` fails. ⭐ **Use fixture
signing contexts via `opts[:signing_context]`.**
⚠️ **And the sandbox may not be able to exercise a real systemd scope at all.**
⇒ ⭐ **IF AN ARM CANNOT BE RUN IN THERE, MARK IT `UNVERIFIED` AND STOP — do not
simulate it and do not report a live measurement you could not have taken.**

## Suites

⛔ **`bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK.** **Baseline
pasted verbatim as measured:**
```
  5 doctests, 3532 tests, 0 failures, 12 excluded, 1 skipped  (seed 117514, rc=0)
  --- state the run STARTED in … [stamp-v2] ---
  sha:        9025bb57 (DIRTY — 2 tracked file(s) …, AND 1 UNTRACKED test file(s) adding tests)
  test state: DIRTY — tmp/test_data/root present (written 2026-04-27)
  deps:       repo deps/   cwd: /home/jes/commonplace/apps/commonplace
```
⚠️ **That run's dirt was S91, since landed as `f5a43043`; `3532` is the correct
expectation for your base.** ⭐ **`[stamp-v2]` sees untracked test files — a v1
`clean` meant "clean EXCEPT possibly untracked tests".**
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
  Environment-sensitive; `canary_result == ""` where "absent" is expected — an
  EMPTY probe result, not a wrong one. Passes in isolation.
  ⛔ A DIFFERENT error shape there is YOURS.
```
⚠️ **`CX-7rjn` is FIXED at `2e693cd6` — a `DeniedWriteReportingTest` failure now
is NEW and is yours.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`
  — workspace-relative, NOT repo-root, NOT `data/`.*
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.**
- ⭐⭐ **REDIRECT TEST OUTPUT TO A FILE AND GREP THE FILE.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES**,
  including in the measured zeros above. ⭐ *Five rounds running have corrected
  this brief's author.*
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to implement the
  absence-scan instead of the positive declaration, or to loosen the canary test.
- ⭐⭐ **WHAT WAS THIS COPIED FROM, AND WHAT HAS BEEN COPIED FROM THIS?**

## Review criteria

A mandatory positive declaration checked at launcher birth; a refusal that names
the missing field; the positive control run against the SERVE'S OWN CONFIG rather
than a manufactured bare env; the quiet half showing a declared runner still
starts; both outcomes printed and shown to differ; no absence-scan anywhere; the
canary test not loosened; per-file counts, the suite total, and the population
delta by hand.

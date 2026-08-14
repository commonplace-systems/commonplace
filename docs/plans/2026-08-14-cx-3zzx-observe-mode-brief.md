# CX-3zzx follow-on: OBSERVE MODE — measure the corpus before requiring it

> **The work's ticket is CX-3zzx.** Base: **the commit that adds this brief**
> — ⚠️ *not a sha; committing a brief moves HEAD past any sha it records.*

## Why this exists

`bin/bd-repo-guard` landed @`316806ab` and is **sound**: it discriminates the
two real repos (`commonplace` REFUSES as declared-frozen, `hermes` PERMITS as
live-shaped), and the declaration travels with a checkout.

⛔ **The HOST is not ready, measured by the host owner across every `.beads`
repo on the box:**

```
repos with a .beads dir     84
guard would REFUSE          69
   …of those, NON-EMPTY     69   ← every one actually uses bd
```

⇒ ⭐⭐ **INSTALLING THE REFUSING GUARD TODAY WOULD BE RED ON CORRECT STATE IN 69
PLACES.** ⚠️ *That is `CX-h062`'s defect again, and this project shipped it once
already today.* ⛔ **It is NOT a design flaw — fail-closed is correct.** ⇒ **THE
GAP IS THAT THE DECLARED-FACT CORPUS DOES NOT EXIST YET: exactly ONE repo on
this box declares a policy.**

⭐ **The specimen that proves the design is right anyway: `wimble` is a live
worker whose FOUR worktrees split THREE-TO-ONE — three unclassifiable, one
permitted — purely because that one happens to carry `.beads/dolt`.** ⇒ ***Same
project, same tooling, opposite verdicts.*** **Shape-sniffing was never going to
be enough; the declaration is the right key.**

## ⭐ What to build: OBSERVE MODE

**The guard REPORTS what it WOULD refuse and REFUSES NOTHING.** ⇒ *The
unclassifiable set becomes a measured, shrinking number instead of an argument;
repos declare as they are touched, by whoever is already in them for another
reason; and the flip to enforce happens when the remaining set is one the host
owner is content to have refused.*

⭐ **This is observe-then-require, the migration pattern this project has already
shipped three times** (trust posture, absent-config default, manifest temporal
exception). ⛔ **AND IT IS WHAT KEEPS BOTH VERDICTS TRUE AT ONCE — the artifact
is sound AND the host is not ready — instead of one decaying into the other.**

## ⛔⛔ THE PROPERTIES, because this thing will sit in front of EVERY `bd` ON THE BOX

1. ⭐⭐ **OBSERVE MODE NEVER REFUSES. IT ALWAYS DELEGATES.**
2. ⭐⭐ **STDOUT MUST BE BYTE-IDENTICAL TO THE REAL BINARY'S.** ⛔ *Callers pipe
   `bd ... --json` into parsers; one extra line breaks them silently.*
3. ⭐⭐ **THE EXIT CODE MUST PASS THROUGH EXACTLY, INCLUDING NON-ZERO.** ⚠️ *A
   wrapper that swallows a failure is the classic form of this bug.*
4. ⭐⭐ **THE WOULD-BE VERDICT MUST BE RECORDED SO THE SET IS COUNTABLE PER REPO
   — AND THE RECORD GOES TO NEITHER STDOUT NOR STDERR.**
   ⛔ **BOTH STREAMS MUST BE BYTE-IDENTICAL TO THE UNWRAPPED BINARY'S.** ⚠️ *This
   is stricter than "don't pollute stdout" and it is deliberate: the installer
   will `cmp` BOTH streams, so a record written to stderr FAILS ACCEPTANCE even
   though it looks harmless.* ⇒ **So the record needs a third destination that
   survives across invocations.** *Prescribing the property, not the mechanism —
   say what you chose and why, including where it lives and what cleans it up.*
5. ⭐ **OBSERVE MUST BE THE DEFAULT**, so installing is safe. ⛔ **The flip to
   enforce must be ONE deliberate, reversible switch** — *say exactly what a
   person types to flip it, and what they type to flip it back.*
6. **Enforce mode's existing behaviour must not be lost** — the three arms
   already demonstrated must still hold when enforce is selected.

## ⛔⛔ TESTING — NEVER INVOKE A REAL `bd`

**The guard already has the seam: `BD_GUARD_REAL`.** ⇒ ⭐ **Point it at a STUB
you write, which records that it was called, prints known bytes on stdout, and
exits a chosen code.**

⛔ **DO NOT invoke a real `bd` in any repo, including this one, and including a
read.** ⚠️ *Measured today: a `bd` READ in a database-less directory CREATES
`.beads/dolt` and starts Dolt runtime state.* ⭐ **The stub is what makes every
arm below safe AND checkable.**

## ⛔ Acceptance — all arms verbatim

1. **FROZEN repo, observe** → the stub RAN; the guard recorded **"would
   refuse"**; nothing was refused.
2. **LIVE repo, observe** → stub ran; recorded **"would permit"**.
3. **UNCLASSIFIABLE repo, observe** → stub ran; recorded **"would refuse
   (unclassifiable)"**. *This is the 69-repo case — it is the one the whole
   round exists for.*
4. ⭐⭐ **STDOUT BYTE-IDENTICAL**: compare the guard's stdout to the stub's own
   output with `cmp`, not by eye. **All three cases.**
5. ⭐⭐ **NON-ZERO PASSTHROUGH**: a stub that exits **7** must make the guard exit
   **7**. ⛔ *Not 0, not 1.*
6. **ENFORCE still refuses**: frozen → refuses without calling the stub.
   *(Prove the stub was NOT called — an unrun stub is the evidence.)*
7. ⭐ **THE COUNT IS DEMONSTRABLE**: show the command that counts distinct repos
   in the would-refuse set, and run it against your fixtures. ⚠️ **A record
   nobody can count is not a measurement.**
8. **Lands as files with their own counts from the tree.**

## ⚠️ Construct the whole state

⭐ *Earned today at the cost of a round's numbers:* a one-file fixture produced a
world **that exists nowhere** and 106 meaningless failures. ⛔ **Build fixtures
your own classifier actually reads, and say what you built.**

## Suites

⛔ **Run `bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK; read the
`BEFORE` line.**

```
host DIRTY   3505 tests, 0 failures   seed 117514
host CLEAN   3505 tests, 0 failures   seed 117514
```
⚠️ **Two sandbox runs disagree — one `3505/2` (`chat_view_compute_supervisor_test.exs`
`:172`, `:143`), the next `3505/0`. Filed `CX-s9kc`, non-deterministic, NOT
yours.** ⛔ **Anything else IS yours.**
⛔⛔ **AND IN A FRESH WORKTREE `mix format --check-formatted` EXITS `rc=1` WITH
"Unknown dependency :phoenix given to :import_deps" — THE SAME EXIT CODE AS
"files are not formatted", FOR A DIFFERENT REASON.** ⇒ ⭐ **Never branch on `rc`
alone: a real format failure LISTS FILE PATHS; a dependency failure NAMES A
DEPENDENCY.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact.** ⛔ **Do
  not install anything, do not change `PATH`, do not touch `~/.local/bin`.**
- ⛔ **Do not run `mix format` (tree-wide) or `mix precommit`.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to invoke a real `bd`
  "just to check", or to let observe mode alter stdout "harmlessly".
- ⭐⭐ **REQUIRE THE FAILURE TO BE READABLE:** *when each arm fails, WHAT PRINTS?*

## ⭐⭐ THE INSTALLER HAS PRE-COMMITTED, AND THESE ARE HIS CHECKS VERBATIM

**This is a YES IN ADVANCE, not a maybe: he installs in observe mode once these
are demonstrated.** ⇒ ⭐ **So make each one checkable BY HIM, not just true.**

```
① stdout BYTE-IDENTICAL      cmp against the unwrapped binary, on a real command, not by eye
② exit code passthrough      a stub exiting 7 → guard exits 7   (0 and 1 both = FAIL)
③ observe truly silent       stdout AND stderr unchanged in a repo it would refuse
④ the flip, BOTH directions  he types it, watches it enforce, types it back, watches it stop
⑤ the 69 count REPRODUCES    from the INSTALLED copy, so the number is the guard's, not his survey's
```

⛔ **THE ONE THAT STOPS HIM EVEN WITH THE REST GREEN: any case where observe mode
CHANGES A CALLER'S BYTES OR STATUS.**

⚠️ **⑤ IS NOT YOURS AND MUST NOT BE ATTEMPTED — it requires the installed copy on
the host and a survey of 84 real repos.** ⇒ ⭐ **What you owe it is the
COUNTING COMMAND, working against your fixtures, in a form he can point at the
real box afterwards.** ⛔ **Do not survey the box. Do not read other people's
repos.**

## Review criteria

Observe never refusing and always delegating; stdout byte-identical by `cmp`;
non-zero passthrough proven with a 7; enforce still refusing without calling the
stub; the would-refuse set countable by a stated command; and the enforce flip
named as something a person types, both directions.

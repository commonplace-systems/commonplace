# CX-0ktk build brief: a permanent state-leak detector, not a bug hunt

> **The work's ticket is `CX-0ktk`.** Base: **the commit that adds this brief**
> — ⚠️ *not a sha; committing a brief moves HEAD past any sha it records.*

## ⛔⛔ THE DELIVERABLE IS AN INSTRUMENT THAT HAPPENS TO SOLVE `CX-0ktk`

**NOT a `CX-0ktk` fix that happens to be reusable.** ⇒ ⭐ **The detector STAYS IN
THE SUITE and makes this whole class SELF-REPORTING: the next state leak names
itself on the run that introduces it, instead of costing a day nine months
later.** ⚠️ **Those two framings produce different code, and only the first
survives the ticket closing.**

## Build

**An ExUnit hook that snapshots the relevant globals after every test and names
the FIRST test whose EXIT state diverges from its ENTRY state.** Suggested
watched set (see the hypothesis warning below): `:commonplace` app env
`:data_dir`, `:trust`, `:local_write_gate`, and whether the node signing
public-key artifact exists.

⇒ ⭐ **It finds the leaker DIRECTLY, at ANY seed, and NEVER SUBSETS ANYTHING.**

## ⛔⛔ NEVER SUBSET — this is why the approach was chosen

**Three elimination methods were tried today and ALL THREE were refuted, because
every way of looking at a subset IS a perturbation of the ordering under test:**

```
"bisect the population"            deleting files RESHUFFLES the deck
"replay prefixes, ordering forced"  --seed 0 changes INTRA-module order too
RestoreTest + victim (the pair)     19 tests, 0 failures
```

⇒ ⭐⭐ **THE NAMED LAW (plan, filed as `7n3`): A PROCEDURE THAT ASSUMES THE THING
UNDER TEST IS STABLE UNDER THE PROCEDURE'S OWN PERTURBATION.** ⛔ ***The confound
is not a fence — it is THE MEASUREMENT ACT ITSELF.*** ⭐ **Remedy: observe
without intervening, or accept you are measuring your own intervention.**

⛔ **IF YOU FIND YOURSELF DELETING, SLICING, OR RE-SEEDING THE POPULATION TO
NARROW THIS DOWN, THAT IS THE SIGNAL YOU HAVE DRIFTED BACK INTO THE REFUTED
METHOD. STOP AND REPORT.**

## ⛔⛔ ACCEPTANCE ① — THE DETECTOR SHIPS WITH ITS OWN POSITIVE CONTROL

**A DELIBERATELY-LEAKING FIXTURE TEST that mutates a watched key and does not
restore it. The detector MUST catch it AND NAME IT.**

⇒ ⛔⛔ ***WITHOUT THIS, A CLEAN RUN IS INDISTINGUISHABLE FROM A DETECTOR THAT
WATCHES NOTHING.*** ⭐ **§15's stronger form: THE FIXTURE MUST ATTEMPT THE
FORBIDDEN ACT — a real leak, not an assertion that the hook ran.**
⚠️ *A check never seen red is not known to work; `CX-1f64` sat unfired for
months and its red arm was the whole ticket.*

## ⚠️ ACCEPTANCE ② — THE WATCHED SET IS A HYPOTHESIS, AND A CLEAN RUN IS A FINDING

⛔ **A clean detector run does NOT mean "no leak". It means "NOT IN THESE
FOUR".** ⇒ ⭐ **Report it as a NARROWING, never as a null result** — *and say
which keys were watched, so the next round knows what was excluded.*
⚠️ *This is the same shape as this morning's mid-run zero: an incomplete corpus
returning a confident nothing.*

## ⭐⭐ ACCEPTANCE ③ — YOUR OWN TESTS WILL MOVE THE DECK. PLAN FOR IT.

**Adding the detector and its fixture CHANGES THE POPULATION, which reshuffles
the suite at a fixed seed.** ⇒ ⚠️ **`CX-0ktk`'s reproducer may STOP REPRODUCING
in your tree. `I3` already did exactly this — its +3 tests killed the failure at
seed `117514`, measured today.**

⇒ ⭐⭐ **THIS DOES NOT INVALIDATE THE ROUND, AND THAT IS THE POINT OF THE PIVOT:
the detector reports leaks whether or not the victim happens to fail.** ⇒ **So
report TWO things separately and do not let one stand in for the other:**
1. **WHICH TESTS THE DETECTOR NAMES AS LEAKING** (the deliverable), and
2. **whether `MUD.RoomVisibilityTest` still fails in YOUR population** (context).
⛔ **A green victim is NOT evidence the leak is fixed. Say which you observed.**

## ⚠️ Facts already measured today — do NOT re-derive these

- ✅ **The failure SURVIVES `--trace` (which forces `max_cases 1`)** ⇒ **pure
  SEQUENTIAL state contamination, NOT concurrency interleaving.** ⛔ *So
  `CX-5gkw`'s load/time-budget playbook does not apply here.*
- ⛔ **`Reflog.RestoreTest` + victim → 19 tests, 0 failures**, with the
  victim-alone control green at 13/0. ⚠️ *That hypothesis had MECHANISM,
  ADJACENCY (modules 136→137) and SYMPTOM all agreeing, and was still wrong.*
  ⭐ ***Convergence is not confirmation.***
- ⛔ **Prefix replay in traced order → 1240 tests, 0 failures** at `--seed 0` AND
  at `--seed 0 --max-cases 1`.
- ✅⭐ **WITH `apps/commonplace/tmp/test_data` STASHED AWAY ENTIRELY (absent), the
  failure STILL REPRODUCES: `3510 tests, 1 failure`.** ⇒ ⛔ **Leftover on-disk
  state from previous runs is NOT required. The contamination is ENTIRELY
  WITHIN-RUN.** ⭐ *This also rules out `CX-hzad`'s family, whose whole
  discriminator was clean-vs-dirty `tmp/test_data`.* ⚠️ *That directory was
  restored with `mv` (mtimes preserved) and the restore verified independently
  — do not go looking for it missing.*
- ⚠️⚠️ **`local node self-trust was not added: node signing public-key artifact
  is absent` IS AMBIENT — it appears in tests that PASS** (four consecutive
  passing tests in `Bd.TicketCreateImportVerbsTest`). ⛔ **Do not build a
  mechanism on it. "Present at the scene" and "causal" are different claims.**
- **The actual assertion:** `assert out =~ "Owner's Den"` gets
  `"(this place has no description)"` (`room_visibility_test.exs`, grep for
  `self-read`). **Whether that is an unwritten doc or a gated read is NOT
  established.**

## ⛔ RUN IT ALONE ON THE BOX

**In those words, and say in your report that you did.** ⇒ **`CX-5gkw`
established that load-induced time-budget crossings are the flake mechanism in
this suite, so a run sharing the machine measures LOAD, not ORDER.**
⚠️ ***"Run it when convenient" and "run it alone" are indistinguishable in a
report afterwards*** — so the report has to make the claim explicitly.

## ⚠️ THE SANDBOX CANNOT SIGN — plan for it, do not discover it

**`node_signing_key` is MASKED in your fence, so
`Commonplace.Crypto.NodeIdentity.signing_context/0` FAILS and no node-signed
write succeeds there.** ⇒ **Use the injectable `opts[:signing_context]` seam;
`Bursar`, `Frontier.Server`, and the `Identity.SpawnCeremony` rounds are worked
examples.** ⛔ *A round assuming ambient node signing produces a confident wrong
diagnosis, not a stuck run.*
⚠️ **And note: a full suite DOES run in a worktree despite the baseline block
saying "no repo `deps/`" — S71 ran 3506 tests inside one. That constraint was
measured and does not bind.**

## Suites

⛔ **Run `bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK; read the
`BEFORE` line.** **Host at `ae939dbf`, population 3510:**

```
seed 1        3510, 0 failures
seed 424242   3510, 0 failures
seed 117514   3510, 1 FAILURE   ← CX-0ktk itself, the thing you are here for
```

⚠️ **`bin/cp-suite-baseline` DEFAULTS TO SEED `117514`.**
⚠️⚠️ **AND PER ACCEPTANCE ③: once your tests land, that red may VANISH. If it
does, REPORT THE DISAPPEARANCE — do not bank the quieter suite.** ⭐ *`I3`'s
round hit this exact case today and reported it; that report is why we knew the
reproducer was perishable.*
⚠️ **`CX-s9kc`: two sandbox runs have disagreed historically
(`chat_view_compute_supervisor_test.exs`), non-deterministic, NOT yours.**
⛔ **Anything outside those two named tickets IS yours.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`
  — workspace-relative, NOT repo-root, NOT `data/`.*
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.** *`bin/cp-format-changed`
  gates only files a commit touches.*
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES
  rather than satisfying it.** ⚠️ ***Its author has now been wrong THREE TIMES
  about the method for this very ticket*** — `OR LATER`, then `bisect the
  population`, then `replay prefixes`, each written to fix the previous one and
  each smuggling the same defect one level down. **If the detector approach is
  also wrong, that is the single most valuable thing you can tell me.**
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to narrow by subsetting,
  or to report a clean watched-set run as "no leak".
- ⭐⭐ **WHAT WAS THIS COPIED FROM, AND WHAT HAS BEEN COPIED FROM THIS?**

## Review criteria

A permanent in-suite instrument rather than a one-off script; a deliberately
leaking fixture demonstrated to be CAUGHT AND NAMED; the watched set stated with
a clean run reported as a narrowing rather than a null; no subsetting anywhere;
the victim's status reported SEPARATELY from the detector's findings; and the
run stated to have had the box to itself.

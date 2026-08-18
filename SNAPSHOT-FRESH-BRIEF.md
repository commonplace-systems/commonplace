# S-snapshot-fresh-s3 — the fresh-worktree arm: is the crash window OPEN here?

> Ruled by commonplace-plan, channel ruling 2026-08-18 (#12876), receipt @7343042
> IN THE commonplace-plan REPO. Third round of the S-snapshot arc; the two
> prior rounds' briefs, reports, and instrumentation are in THIS worktree
> under artifacts/S-snapshot/ (read ACCEPTANCE.md and MECH-ACCEPTANCE.md
> first; do not redo their stages).
> Base: this worktree — branch `sol/s-snapshot-fresh-s3`, created from the
> artifact branch tip (product code identical to origin/main; the extra
> commits are round artifacts only). A RELATION, not a sha.
> Work label: S-snapshot AND NO OTHER ID.
>
> ⛔⛔ MEASUREMENT ONLY, NO FIX, NO PROVOCATION (no deleting/creating store
> dirs by hand — the entire point is watching what appears on its own).
> Temporary instrumentation of the ONE test file is in scope; apply it FROM
> THE ROUND-2 DIFF (below), cp-backup first, cp-restore after, show the
> restore is byte-clean.
>
> ⚠️⚠️ THE ONE PRECONDITION THIS ROUND EXISTS FOR: this checkout has NEVER
> run tests — `tmp/` does not exist at worktree root NOR under
> apps/commonplace_cli (verified at creation). ⛔ DO NOT run any suite,
> command, or "warm-up" beyond what this brief lists, in any order other
> than listed — an extra early run could close the very window under test.
> FIRST ACTION after reading the artifacts: `ls tmp apps/commonplace_cli/tmp`
> and RECORD the result (both should be absent; if either exists, STOP and
> report — the precondition failed).

## Your environment — as the prior briefs

bwrap sandbox, workspace-write, egress open by ruling. ⛔ `.git` READ-ONLY —
never commit. ⛔ No live-store (`/home/jes/commonplace/workspace/.commonplace/commits/`)
or serve contact. Anything measured inside the fence inherits the fence.
`mix deps.get` may be needed (a hex cache write failure like round 1's is
non-fatal if compile then passes); `mix compile --warnings-as-errors` must
pass BEFORE instrumentation and AFTER it.

## THE PRE-DECLARED READINGS — both directions, written before the data

THE LABELED READING UNDER TEST (from s2's measured facts; it must be able to
lose): CubDB's State.data_dir is the RELATIVE "tmp/test_data/commits";
compaction CREATES by path against current cwd; in a never-run checkout the
app-dir store does not exist, so a compaction firing at test-time cwd hits
{:error, :enoent} — until ANY invocation creates the app-dir commits tree,
which closes the window permanently (SELF-EXTINGUISHING).

```
CONFIRMED  = red at LOW rep count (round 1 fired at rep 4 in a then-fresh
             worktree) AND the probe shows the app-dir commits path FLIPPING
             absent→present across the run AND, in invocations AFTER the
             flip, reds CEASE.
REMOVED    = bounded-N green IN THIS FRESH WORKTREE — that removes the
             reading's main support. Say it plainly; do not reinterpret.
THIRD      = red with a DIFFERENT body, or a flip without reds ceasing, or
             reds without a flip — report exactly what the probes show.
```

## Procedure — order matters, record everything

0. Read artifacts/S-snapshot/{ACCEPTANCE,MECH-ACCEPTANCE}.md. `ls` both tmp
   locations (record). deps.get / compile as needed (record).
1. Apply artifacts/S-snapshot/mech-instrumented.diff to the test file
   (cp-backup first). Its CX_SNAPMECH probe already logs, per rep: cwd,
   configured data_dir + exists/ls, CubDB pid + State.data_dir + exists/ls
   of it (relative ⇒ resolves at CURRENT cwd — that IS the app-dir check),
   and pid stability. Compile must pass.
2. Invocation 1: `mix test <file>:<line-of-"writes a snapshot commit">
   --repeat-until-failure 200` from the WORKTREE ROOT (the same invocation
   shape rounds 1–2 used), output to its own log. 20-minute cap.
3. ⭐ DO NOT STOP AT THE FIRST RED. Whatever invocation 1 produced, run up
   to 4 MORE invocations of the same command (each to its own log, serial,
   port-4002 caveat, verdict line checked) — if the reading is right, reds
   appear early and then CEASE once the app-dir tree exists; the ceasing is
   the self-extinguishing signature observed live. Total budget: 60 min or
   5 invocations, whichever first; state actuals.
4. After EACH invocation: `ls`/exists of BOTH stores (worktree-root
   tmp/test_data and apps/commonplace_cli/tmp/test_data) and WHICH holds
   boot artifacts (node_id, node_signing_key, node_signing_public_keys.json)
   — this reads the boot-time cwd from where boot artifacts landed, which is
   plan's arm (b) answered locally.
5. Restore the test file by cp; show cmp clean and empty git diff.

## Acceptance — artifacts

- The ls-both-locations record from step 0 (the precondition), and after
  every invocation (step 4).
- Every red's FULL verbatim body + rep number + invocation number, compared
  to round 1's captured body (same/different/partial, quote the differing
  lines).
- The per-rep CX_SNAPMECH lines for any invocation containing a red, and
  for the first invocation regardless.
- THE VERDICT against the pre-declared table: CONFIRMED / REMOVED / THIRD,
  with the specific observations that place it there.
- Discrepancies with this brief (it is a claim, not an instruction) and
  near-misses.

## Suites and known reds

Only the one file runs. No tests added. Population facts: cli app was
121 tests / this file 3 tests at the prior rounds' base.
⚠️ INTERACTION: entry ④ below is about THESE tests; its rules govern push
runs — here a red is the DELIVERABLE. The block's recipe note and
DO-NOT-DELETE line refer to the SIBLING branch (s1); this round's worktree
is a different, deliberately-fresh checkout.


```
KNOWN REDS ON main (as of 80d6e962, 2026-08-18 06:00Z) — NOT YOURS. Anything else IS.

① ⭐⭐ MECHANISM PROVEN 2026-08-18 AND THE FIX HAS LANDED — ENTRY STAYS OPEN
   PENDING CONFIRMATION OVER N CI RUNS. ⛔ IT IS NOT CLOSED, AND ONE GREEN DOES
   NOT CLOSE IT. Read the proof and the status before attributing anything here.
   ✅ THE MECHANISM, pinned by MODULE md5 rather than by narrative: test fixtures
      in engine_module_test.exs defined modules under the PRODUCTION names.
      Module names are BEAM-GLOBAL, so each fixture compile REDEFINED the real
      module's code for the whole run; last_good caches an ATOM, so the victim
      was served the fixture's code. The fixture passes no viewer → gated room →
      :read_denied → swallowed by a catch-all → missing room content. THAT is why
      only gated/private-room tests ever showed it.
   ✅ FIXES LANDED: (c) `85f357ce` — :mud_engine_manifest joins the leak
      detector's watchlist, the leak that hid it is now visible.
      (a) `316f7b53` / `e8f50d48` — the TEN production Engine* names renamed to
      *Fixture in test/; zero production definitions remain in test/; the five
      real-seed string assertions in seed_sources_test are PRODUCTION content and
      were correctly left untouched. Full suite at (a): 3580 tests, 0 failures.
      (b) e66f706c — verify-at-serve: last_good stores {module, md5} and checks
      it at BOTH serve doors; mismatch ⇒ floor + named alarm, unloaded or
      unverifiable entries REFUSED rather than served. THE FIX SPACE IS CLOSED.
   ⛔ A LINE SAYING "(b) IS NOT DONE" STOOD HERE FOR ~40 MINUTES AFTER THE LINES
      ABOVE SAID IT HAD LANDED — TWO ADJACENT CLAIMS IN OPPOSITE DIRECTIONS, in
      the one file whose entire purpose is that a round can trust what it pastes.
      ⇒ IT CAME FROM EDITING THE NEW STATE IN WITHOUT DELETING THE OLD STATE OUT.
        An append is not an update, and a block is not a changelog: the changelog
        is below the end marker precisely so the BLOCK can hold one present tense.
      ⇒ ⭐ AFTER EVERY EDIT HERE, READ THE WHOLE ENTRY BACK — a diff shows what you
        added and CANNOT show what it now contradicts.
   ⛔⛔ WHY THIS ENTRY STAYS IN THE BLOCK ANYWAY: the family's CI rate is expected
      to COLLAPSE, and expected-to-collapse is a PREDICTION, not a measurement.
      The clock starts at `316f7b53`; it closes on consecutive CI runs, never on
      one green. Until then a matching failure is still NOT YOURS.
   ── the history below is what the entry looked like before the proof; it is
      kept because a recurrence needs it, not because it is still the state ──
   MECHANISM (as previously characterised): AN ARRANGEMENT-TRIGGERED MUD RENDER
   RETURNS WITHOUT ITS EXPECTED ROOM CONTENT. Same tests at a DIFFERENT SEED and
   the SAME POPULATION are GREEN — arrangement, not count and not code.
   ⇒ ⭐ AND THAT CHARACTERISATION WAS RIGHT BUT SHALLOW: "arrangement" was the
     OBSERVABLE of fixture-compile ORDER deciding whose code owned the atom.
   ⚠️ THREE KNOWN INSTANCES. This list is INSTANCES OF THE MECHANISM, not the
      definition of it — a FOURTH test showing the same mechanism is covered here
      even though it is not named yet. Tell me and I will add it.
     MUD.RoomVisibilityTest      — owner's own look on their gated room
     MUD.WebPlayIntegrationTest  — citizen spawns in owned home
     MUD.HumanWebPlayTest        — human_web_play_test.exs:214, "zyee: greet lands
                                   Welcome + room ... a later look returns its OWN
                                   room, not the stale banner"
   ⛔ THE ASSERTION STRINGS DIFFER AND THAT IS NOT A DISQUALIFIER. Two instances
      fail on "(this place has no description)"; the third fails on a MISSING ROOM
      NAME ("sam's Home") with that count at ZERO in the same run.
      ⇒ KEYING ON THE SYMPTOM STRING IS AS NARROW AS KEYING ON A MODULE IS BROAD.
        The first cost us: instance ③ arrived UNCOVERED because the block named a
        string rather than the mechanism.
   ⚠️ HONEST LIMIT: SAME FAMILY, SHARED MECHANISM NOT PROVEN. One symptom across
      two tests is corroboration, not proof, and the third has a third assertion.
   Full suite CURRENT: 3582 tests, 0 FAILURES, 16 EXCLUDED — and the two halves
   of that line have DIFFERENT AS-OFS, which is the point of stating both:
       3582 tests   as of 80d6e962   (3581 + 1, the gc7q refusal test; delta
                    predicted by its author BEFORE the run, and CI agreed)
       16 excluded  as of 1d502586   (12 + four perf arms deliberately :scale)
   ⛔ AN EXCLUSION COUNT IS PART OF THE POPULATION, NOT A FOOTNOTE. A round that
      compares 3581 against a run with a different :scale posture is comparing
      two different suites and will read the gap as its own defect.
   ⚠️ EARLIER READINGS, kept so the deltas stay legible: 3580/0 at 316f7b53
      (post-(a)); 3569 tests / 1 FAILURE (MUD.HumanWebPlayTest) at 0d4163ac
      (pre-fix, seed 117514).
   ⛔ AND BY THIS ENTRY'S OWN RULE THAT ZERO IS UNINFORMATIVE, THIS GREEN IS NOT
      THE CONFIRMATION. It is consistent with the fix and also consistent with
      the arrangement simply not firing. The confirmation is the CI rate over N.
   ⭐ CONTROL THAT MAKES IT ARRANGEMENT AND NOT S99's CODE — same population,
      different seed: 117514/3569 → 1 failure · 424242/3569 → 0 failures.
   ⛔⛔ THIS IS NOT FIXED, RESOLVED, OR CLOSED, AND THE ENTRY MUST NOT BE DELETED
      FOR BEING GREEN. Observed sequence:
          population 3541 → 2 failures
          population 3546 → 1
          population 3548 → 1
          population 3553 → 0     ← a green that proves nothing
          population 3563 → 1     ← RED AGAIN, ONE ROUND LATER. The trap fired for
                                    real: had this entry been deleted at 3553 for
                                    being green, S98 would have been told by our own
                                    rule that this failure was ITS.
          population 3569 → 1     ← a THIRD test, a THIRD assertion string
      THE ENTRY'S CLAIM IS THAT THE COUNT IS ARRANGEMENT-DEPENDENT, SO A ZERO IS
      EXACTLY AS UNINFORMATIVE AS A ONE. Neither a zero nor a nonzero is a signal.
   ⛔ A KNOWN-RED DELETED WHILE GREEN IS A TRAP ARMED FOR WHOEVER ARRIVES NEXT:
      the next round that adds tests and sees it red has no block to check, is
      told by our own rule that unlisted failures are ITS, and hunts a defect
      that is days old.
   ✅ STILL DETERMINISTICALLY REPRODUCIBLE at seed 117514 / population 3541 via
      the recipe (fc7d4bf6). The handle is intact; it is simply not firing here.
   MECHANISM: ARRANGEMENT, not count and not code — the same tests at seed 424242 are GREEN.
   Reproducer + the dead-lead table: dba2e59e, d19361f7, deaa6464 (3 commits; the
   TABLE holds eight rows — the commit count and the lead count are DIFFERENT NUMBERS
   and this line used to imply they were the same). Landed red at cf430433
   under commonplace-plan's escape condition; the red is the documented MUD mechanism,
   NOT S94 (per-file S94: 10 tests, 0 failures, boot verified).
   ⛔ DO NOT CHANGE THE SEED TO MAKE IT PASS. That trades a DETERMINISTIC red for an
      INTERMITTENT one, which gets attributed to whoever is unlucky rather than to the
      defect — and it destroys the only handle anyone has on this class.
   ✅ SUPERSEDED 2026-08-18 — this line used to read "MECHANISM IS UNMEASURED and the
      one named closing condition is SPENT ... no further round without a NEW FACT."
      ⭐ THE NEW FACT ARRIVED AND IT WAS AN ARTIFACT IDENTITY, NOT A REPRODUCER:
      FOUR minimal reproducers had already failed — two- and three-file sets stayed
      green at 14 seeds including forced order, because the atom's post-module state
      in small sets happened to be benign. Fishing for orders was the wrong search.
      md5 equality with the fixture compiles and INEQUALITY with the real seed was
      the discriminator narrative could not fake.
   ⇒ ⭐ TRANSFERABLE: when a defect resists minimisation, stop shrinking the input
     and start asking WHAT WAS ACTUALLY SERVED. Identity beats reproduction.
   ⛔ A failure in these files that does NOT match the MECHANISM above IS yours.
      (Not "a different string" — a different MECHANISM. If a render comes back
       missing expected room content and a same-population different-seed run is
       green, it is this entry, whatever the assertion says.)
   ⛔⛔ IF YOUR ROUND ADDS TESTS, THE POPULATION CHANGES AND SO DOES THE ARRANGEMENT.
      At 3569 + N these MAY COME BACK RED OR GREEN, and NEITHER IS A SIGNAL ABOUT
      YOUR WORK. Do not report "I fixed the MUD red" and do not report "I caused it" —
      both are available, both are plausible, and both are false. Report your per-file
      counts and the suite total WITH ITS POPULATION, and say nothing about causation.

② KNOWN TRIGGER — Runner.LauncherTest, "pod cannot read a canary injected by its
   launching BEAM". Environment-sensitive (CX-kacr); a stray tmux socket has triggered it.
   Fails as canary_result == "" where "absent" is expected — an EMPTY probe result, not a
   wrong one. Passes in isolation.
   ⛔ DO NOT "FIX" BY LOOSENING THE ASSERTION. That test refuses to treat "" as "absent",
      which is exactly why it goes red instead of quietly passing.
   ⛔ A DIFFERENT error shape there is yours.

③ ⭐ RESOLVED 2026-08-17 — THE FOUR-DAY CI RED IS CLEARED. Kept as a RETIRED entry
   below the block so nobody re-derives it. THREE STACKED CAUSES, all measured:
     ① bwrap NOT INSTALLED on ubuntu-latest   9 × {:error, :bubblewrap_not_found}
        → installed, AND verified at the install step by name
     ② unprivileged userns RESTRICTED          apparmor_restrict_unprivileged_userns=1
        → granted via AppArmor's OWN mechanism: bwrap registered under a scoped
          profile. THE DEFAULT IS UNTOUCHED. Approved by jes 2026-08-17 after he
          declined the sysctl flip AND initially declined this, then reversed.
        ⭐ RE-PROVEN EVERY RUN: the step copies bwrap to an unprofiled path and
          asserts THE COPY IS DENIED — if the machine is ever open, CI goes red.
     ③ THE FENCE'S OWN BUG: masks assumed their target dirs existed. They exist on
        THIS host only because a tmux is running. ⇒ ONLY A SECOND MACHINE COULD
        HAVE FOUND IT. The four-day red was the pod work's first portability test.
   ⇒ POD/LAUNCHER/RUNNER FAILURES IN CI: ZERO, for the first time in the fence's
     existence. Verified independently on run 32041543228 (log 2,220,484 bytes):
     bubblewrap_not_found → 0.
   ⚠️ THE EXIT CRITERION IS NOT MET. One green is one data point. Pre-fence baseline
      was 47/66 = 71% green, so a ~29% instability PREDATES the fence, is UNOWNED,
      and is now observable for the first time.

④ KNOWN INTERMITTENT — Commonplace.CLI.SnapshotTest (commonplace_cli, 121 tests).
   ⛔ TWO KNOWN ASSERTIONS, AND THE SECOND IS WHY THIS ENTRY WAS REWRITTEN WITHIN
      THE HOUR OF BEING WRITTEN:
        "snapshot command returns :path_not_found when the path does not resolve"
                                          ×2  (0bf50a30, a2efb172)
        "snapshot command writes a snapshot commit for the resolved doc"
                                          ×2  (bb086a53, 80d6e962)
   MEASURED RATE: 4 of the last 11 completed push runs (2026-08-18 06:00Z), and
   separately 2 of 7 on 2026-08-16 — call it ~30-35%, not a rarity.
   ⭐ ONE CAPTURED ERROR BODY (80d6e962, by commonplace — the first anyone has
      taken for this flake). ⛔ READ IT AS ONE OBSERVATION'S SHAPE, NOT AS THE
      MECHANISM: it is a single sample and the entry does NOT claim it explains
      the other three.
        ** (exit) exited in: GenServer.call(Commonplace.Store.CommitStore,
             {:create_commit, ...}, 5000)
           ** (MatchError) no match of right hand side value: {:error, :enoent}
               (cubdb 2.0.2) lib/cubdb.ex:1499: CubDB.trigger_compaction/1
      ⇒ CubDB COMPACTION crashed on :enoent inside the app-default CommitStore
        during the snapshot's create_commit — the store's files were missing when
        compaction fired.
      ⚠️ IF YOUR RED HERE HAS A DIFFERENT ERROR BODY, SAY SO — a second shape
         would mean this entry covers two things and needs splitting, and that
         is worth more than another sighting of the same one.
      ✅ ASKED AND ANSWERED 2026-08-18 06:10Z: the reproduction's inner crash is
         BYTE-IDENTICAL to the CI body above. The OUTER frame differs — CI crashed
         in Snapshot.do_run (test body), the repro in the file's SETUP at line 41 —
         and that is NOT a split: same store, same call, same CubDB failure at the
         same line, different phase. THE MODULE+LONE-RED KEY HOLDS.
   ✅✅ REPRODUCED 2026-08-18 (S-snapshot-repro-s1, in-sandbox, rep 4, seed 1745).
      THE HANDLE — a FRESH worktree (see the warning below), then:
        mix test <cli snapshot test file>:71 --repeat-until-failure 200
      → red within ~4 reps (n=1).
      ⛔⛔ THE HANDLE MAY BE SINGLE-USE PER CHECKOUT — READ THIS BEFORE CONCLUDING
         "NOT REPRODUCIBLE". S-snapshot-mech-s2 ran 603 instrumented reps in the
         SAME worktree that fired at rep 4 and got ALL GREEN. Post-round reads
         (CubDB's captured path is RELATIVE; boot artifacts and test state landed
         in TWO different tmp/test_data dirs — a boot-vs-test cwd split inside one
         VM) support a LABELED, NOT PROVEN reading: the crash window CLOSES
         PERMANENTLY once any invocation boots at app cwd — i.e. the reproducer is
         SELF-EXTINGUISHING per checkout.
         ⇒ ⭐ IF THAT READING HOLDS: use a FRESH worktree. Re-running the recipe
           on a worktree that has already been exercised produces a null that
           means "window closed", NOT "bug absent" — AND THOSE TWO ARE THE SAME
           OBSERVATION FROM OUTSIDE. This annotation exists so that a null here
           is not mistaken for a disconfirmation.
         ⇒ IT ALSO EXPLAINS THE ~30% CI RATE WITHOUT ANY NEW MECHANISM: every CI
           run is a fresh checkout, so the window is always open there.
         ⚠️ LABELED READING, awaiting plan's two settling arms (fresh-worktree
            replay + one CI cwd read). Do not cite it as established. Artifacts: branch sol/s-snapshot-repro-s1 @
      fcdd72da (stage logs + ACCEPTANCE.md + brief), verified present on origin.
      ⛔ DO NOT DELETE THAT BRANCH — it is the only durable copy of the REPORT.
      ⛔⛔ AND THE BRANCH DOES NOT PROTECT THE REPRODUCER. Measured 2026-08-18:
         the habitat is /home/jes/sol-snapshot-repro/wt/tmp/test_data (~1 MB of
         accumulated commits) and it is GIT-IGNORED (.gitignore:27 "tmp/").
         ⇒ IT IS IN NO COMMIT, ON NO BRANCH, AND ON NO REMOTE. A single
           `git clean -xfd` in that worktree destroys the precondition — and -x
           is exactly the flag someone reaches for to "tidy up a Sol worktree".
         ⇒ ⭐ THE ARTIFACT AND THE PRECONDITION HAVE DIFFERENT LIFETIMES AND
           DIFFERENT PROTECTIONS. Pushing the branch felt like durability and
           covered only half of what makes this reproducible.
         ⇒ IF THE HABITAT IS LOST: it is re-creatable (run the cli snapshot file
           a few times in a worktree to accumulate commits), just not free.
      WHAT IT NARROWS, as facts and not as a mechanism:
        · fired with ONE test in the BEAM ⇒ within-VM cross-test interference is
          EXCLUDED for the reproduced instance; what persists across reps is DISK
          state (tmp/test_data accumulating commits every rep).
        · 30× whole-cli-app runs ALL GREEN, zero trigger_compaction occurrences.
        · --repeat-until-failure does NOT hold the seed — every rep printed a new
          one, so seed is not the variable.
      ⚠️ STILL NOT THE MECHANISM, and the entry does not claim it. A handle that
         reproduces is not an explanation; it is what makes one affordable.
   ⛔ NOT "STANDING" AND NOT A TRIGGER. If your push goes red ONLY here, RE-RUN
      BEFORE INVESTIGATING: at ~30% a single red carries almost no information.
      ⚠️ THIS LINE HAS BEEN WRONG IN BOTH DIRECTIONS IN ONE HOUR, WHICH IS ITSELF
         THE WARNING. At 06:10Z I wrote that the bug was "driveable on a dirty
         worktree" — accumulated local state summons it. At 06:25Z a 603-rep run
         on that same dirty worktree came back ALL GREEN, and the current reading
         is closer to the OPPOSITE: a fresh checkout is what has the open window,
         and accumulation CLOSES it.
         ⇒ ⭐ I BUILT A RULE ON n=1 AND STATED IT AS A PROPERTY. The single
           reproduction was real; the generalisation from it was mine and it did
           not survive the second measurement.
         ⇒ WHAT SURVIVES BOTH READINGS: in CI it fires at ~30% and nothing a
           round does summons it, so the type is still INTERMITTENT and the
           re-run rule above still stands. THAT is the part a round needs.
   ⛔ A DIFFERENT ASSERTION IN THIS MODULE IS PROBABLY STILL THIS ENTRY. Two of
      the module's tests have now failed with no code between them touching the
      CLI — so the entry is keyed on the MODULE plus the shape "a snapshot-command
      test fails alone, everything else in the run green", NOT on either string.
      ⚠️ THIS IS A DELIBERATE, NARROW EXCEPTION TO "NEVER KEY BY MODULE", and it
      is bounded by the shape: a commonplace_cli failure that is NOT a snapshot
      command test, or one that arrives alongside other failures, IS YOURS.
   ⚠️ MECHANISM UNKNOWN and UNOWNED. This entry buys a round its time back; it does
      not excuse the flake, and ~30% in one module deserves an owner.
```

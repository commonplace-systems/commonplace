# S-snapshot-mech-s2 — WHICH directory was absent, and WHO holds the stale path

> Ruled by commonplace-plan, channel ruling 2026-08-18 (#12871), receipt @96f1deb
> IN THE commonplace-plan REPO. Follows S-snapshot-repro-s1 (its brief and
> artifacts are in THIS worktree — read artifacts/S-snapshot/ACCEPTANCE.md
> first; do not redo its stages).
> Base: this worktree as it stands — branch `sol/s-snapshot-repro-s1` with the
> s1 artifacts committed, PLUS the accumulated `tmp/test_data` state from s1's
> runs. ⚠️ THAT DIRTY STATE IS THE HABITAT: the reproduction fired on a
> worktree whose tmp/test_data had accumulated several runs' commits. Do NOT
> clean tmp dirs, do NOT delete or reset anything under apps/*/tmp.
> Work label: S-snapshot AND NO OTHER ID.
>
> ⛔⛔ MEASUREMENT ONLY, NO FIX — same scope as s1: no assertion changes, no
> setup/teardown "repairs", no product-code changes. TEMPORARY INSTRUMENTATION
> of the test file IS in scope (that is the round): back up the file by `cp`
> first, restore by `cp` after, and show the diff of what you instrumented in
> the report.

## Your environment — same facts as s1's brief

bwrap sandbox, workspace-write, egress open by ruling. ⛔ `.git` READ-ONLY —
never commit; leave everything unstaged. ⛔ No contact with the live store
(`/home/jes/commonplace/workspace/.commonplace/commits/` — workspace-relative)
or any serve. Anything measured inside the fence inherits the fence as a fact.
`mix compile --warnings-as-errors` must pass after your instrumentation edit.

## What s1 established (do not re-derive — artifacts in this worktree)

Single test alone (`apps/commonplace_cli/test/commonplace/cli/snapshot_test.exs`,
the "writes a snapshot commit" test), repetition 4, seed 1745:
`GenServer.call(Commonplace.Store.CommitStore, {:create_commit,...}, 5000)` →
`(MatchError) no match of right hand side value: {:error, :enoent}` at
`(cubdb 2.0.2) lib/cubdb.ex:1499: CubDB.trigger_compaction/1`.
Within-VM cross-test interference EXCLUDED (one test in the BEAM). 30× whole
cli app: green, zero trigger_compaction. Seed not held across reps.

## Facts I verified at HEAD before writing this (selectors included)

- `deps/cubdb/lib/cubdb.ex` line 1499 is `{:ok, store} = new_compaction_store(data_dir)`
  inside `defp trigger_compaction(state = %State{data_dir: data_dir, ...})` —
  so the failing operation is CREATING THE NEXT COMPACTION FILE inside the
  `data_dir` that CubDB's OWN State remembers, and `{:error, :enoent}` means
  that path was not usable AT THAT INSTANT. Read it yourself before starting.
- `:data_dir` is configured as the RELATIVE path "tmp/test_data" (the test
  file pins it; `Application.get_env(:commonplace, :data_dir, "data")` is the
  boot-time read in `apps/commonplace/lib/commonplace/application.ex` — grep
  that exact string). A relative path's meaning depends on the VM's cwd.
- The test file contains ZERO `rm_rf` (selector: `grep -c rm_rf <file>` → 0),
  and NO cli test rm_rf's anything matching test_data (selector:
  `grep -rn rm_rf apps/commonplace_cli/test/ | grep -i test_data` → 0 hits).
  cli's test_helper.exs is two lines: ExUnit.start + loading
  `test/support/file_rm_rf_guard.exs`. ⇒ In a file-alone run, no TEST CODE
  removes the directory. Whatever made it absent is something else — that is
  the question.

## THE LABELED HYPOTHESIS (it must be possible to come back "NOT that one")

commonplace-plan's queue row #1 (2026-08-09) records this byte-identical
signature in a different app, mechanism there ESTABLISHED as: a
production-named singleton captures `data_dir` ONCE AT BOOT; a
deletion/recreation lands under the live store; the tripper can be the
store's OWN BACKGROUND COMPACTION with no test call at all. The hypothesis
for THIS instance: the app-default CommitStore/CubDB singleton survives
across reps holding a captured path, and some across-lifetime state makes
that path unusable at compaction time. THIS IS A HYPOTHESIS. The
instrumentation below can confirm it, refute it, or find a third thing —
report whichever the reads show.

## Instrumentation — exactly these reads, logged per rep

Instrument the test file's `setup` (cp-backup first) to Logger.warning (or
IO.puts to stderr) ONE line per rep, tagged `CX_SNAPMECH`, containing:
  a. `File.cwd!()`
  b. `Application.get_env(:commonplace, :data_dir, "data")`
  c. the CommitStore singleton's view: get the CubDB process's
     `State.data_dir` — reach it via `:sys.get_state` on
     `Process.whereis(Commonplace.Store.CommitStore)` and follow the state
     shape to the CubDB pid, then `:sys.get_state` on that. ⚠️ If the state
     shape is not what you expect, REPORT THE SHAPE YOU FOUND and log
     whatever path fields it carries — a wrong guess about a struct is a
     finding, not a failure.
  d. `File.exists?` of (b) and of (c), and an `ls` (File.ls) of each that
     exists — count of entries is enough, plus any `*.compact` names in full.
  e. the CommitStore/CubDB pids themselves (so pid-stability across reps is
     read, not assumed).

Then run the s1 recipe: `mix test <file>:<line-of-the-writes-snapshot-test>
--repeat-until-failure 200`, output to a log file. Budget: until red or 200
reps or 20 minutes, whichever first; if no red, run the loop up to 3
invocations (state counts). STRICTLY SERIAL, port 4002 caveat as in s1,
verdict line checked per invocation.

## Acceptance — artifacts

- The instrumented diff (shown), the restore (shown by re-diff → empty).
- The per-rep CX_SNAPMECH lines for the invocation that went red (or all, if
  none did), PLUS the failure body if red.
- THE ANSWER, stated from the reads and labeled confirm/refute/third-thing:
  at the failing rep, WHICH path was absent (b's, c's, both), did (b) and (c)
  DIVERGE (the one-read discriminator: divergence = captured-stale-path
  confirmed), and were the pids stable across reps?
- Escape hatch, pre-declared: no red in the budget IS a result — report the
  per-rep reads anyway (they answer pid-stability and path-divergence even on
  green reps) and stop. ⛔ Do not provoke (no deleting dirs to force it).
- Report discrepancies with this brief. Near-misses too.

## Suites and known reds

Only the one file runs (plus your instrumentation of it). No tests added ⇒
no arrangement caveat beyond: your rep count changes tmp/test_data's
accumulated state, which is the habitat — expected, not a contamination.
⚠️ INTERACTION: entry ④ below is about THESE tests; its re-run rule governs
push runs on main — here a red is the deliverable. Entry ④ also now carries
s1's recipe and the DO-NOT-DELETE note for this very branch.


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
      THE HANDLE — a worktree whose tmp/test_data has ACCUMULATED a few runs'
      commits, then:  mix test <cli snapshot test file>:71 --repeat-until-failure 200
      → red within ~4 reps (n=1). Artifacts: branch sol/s-snapshot-repro-s1 @
      fcdd72da (stage logs + ACCEPTANCE.md + brief). ⛔ DO NOT DELETE THAT BRANCH —
      it is the only durable copy of the reproduction.
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
      ⚠️ "NO ACTION OF YOURS SUMMONS IT" WAS TRUE UNTIL 06:10Z AND IS NOW ONLY
         HALF TRUE — the handle below summons it deliberately from ACCUMULATED
         LOCAL DISK STATE. In CI, where every run starts clean, nothing you do
         summons it and the type still reads INTERMITTENT. ⇒ THE TYPE IS ABOUT
         THE HABITAT, NOT THE TEST: same failure, intermittent in CI, driveable
         on a dirty worktree.
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

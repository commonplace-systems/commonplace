# S-snapshot-fix-s4 — absolutize the store path at both doors; kill the class

> Ruled by commonplace-plan, channel ruling 2026-08-18 (#12880), receipt @2ab3d4c
> IN THE commonplace-plan REPO. Fourth round of the S-snapshot arc. The
> mechanism this fixes was CONFIRMED by S-snapshot-fresh-s3 — artifacts on
> branch `sol/s-snapshot-fresh-s3` @05475ffc (a DIFFERENT worktree; read its
> FRESH-ACCEPTANCE.md only if you need context — this brief carries what you
> need).
> Base: this worktree — branch `sol/s-snapshot-fix-s4` from origin/main.
> A RELATION, not a sha.
> Work label: S-snapshot AND NO OTHER ID.
>
> ⚠️⚠️ THIS CHECKOUT HAS NEVER RUN TESTS (both tmp locations verified absent
> at creation) — the red-first demonstration DEPENDS on that. Do not run any
> suite before Phase 1, and follow the phases in order.

## The confirmed mechanism (context, one paragraph — established, not hypothesis)

CubDB stores its data_dir as the RELATIVE string it was given
("tmp/test_data/commits"). The app boots with cwd = worktree root; mix runs
tests with cwd = the app dir. Open fds keep working, but COMPACTION CREATES
BY PATH — re-resolving the relative string against CURRENT cwd — and crashes
`{:error, :enoent}` at cubdb.ex:1499 (`new_compaction_store/1`) when the
app-cwd-resolved commits tree does not exist. The first thing that creates
that tree closes the window permanently per checkout; CI's ~30% rate
persists because CI checkouts are always fresh. Confirmed live: reds at
reps 7/1/1 in a fresh worktree, the app-dir commits/ flip, then 402
consecutive greens.

## Your environment

bwrap sandbox, workspace-write, egress open by ruling. ⛔ `.git` READ-ONLY —
never commit; leave all changes UNSTAGED (the reviewer lands them). ⛔ No
live-store (`/home/jes/commonplace/workspace/.commonplace/commits/`) or
serve contact. `mix deps.get` (hex cache write failure non-fatal if compile
passes); `mix compile --warnings-as-errors` must pass before AND after the
change. ⛔ No tree-wide `mix format` — format ONLY the files you touch
(`mix format <paths>`).

## THE RULED FIX — shape is binding, verbatim from the ruling

**ABSOLUTIZE AT BOTH DOORS. EXPAND, not refuse.** Expansion freezes the
meaning the caller had at open — precisely the intent the bug violated. A
refusal would churn ~100 relative-path call sites for no gain.

Door ① — the boot capture, `apps/commonplace/lib/commonplace/application.ex`:
the line `data_dir = Application.get_env(:commonplace, :data_dir, "data")`
(grep that exact string; it appears TWICE in the file — line ~75 in start/2
and one more capture around ~306; READ both, expand at both if both feed
path consumers — say what you found).

Door ② — the CommitStore handoff, `apps/commonplace/lib/commonplace/store/commit_store.ex`:
`init/1` does `data_dir = Keyword.fetch!(opts, :data_dir)` then
`path = Path.join(data_dir, "commits")` and hands the path to CubDB.
`Path.expand` the data_dir HERE, before any join/lock/CubDB use — we own
this seam; the dep's re-resolution behavior is not ours to patch.

⛔ Each door has callers the other does not cover; ONE DOOR IS HALF A FIX.
⭐ REQUIRED at each expand, an inline why-comment AT THE LINE, citing branch
`sol/s-snapshot-fresh-s3`: the next person who sees a "gratuitous"
Path.expand and deletes it must trip over the reason where they stand. Say
WHAT it prevents (relative store path re-resolved under mix's boot-vs-test
cwd split; compaction creates by path) in one or two lines.

## THE SWEEP — in-round, pre-declared, report-only

Selector: `grep -rn 'Application.get_env(:commonplace, :data_dir' apps/commonplace/lib`
— I count 8 sites at HEAD (application.ex ×2, git_bridge/server.ex,
sync/agent.ex, sync/dir_agent.ex, sync/entry_agent.ex, trust.ex,
workspace.ex; plus doc mentions). READ each hit. Classify: covered by the
two doors (path flows through CommitStore) vs INDEPENDENT capture that
resolves at use (a residual exposure of the same class — REPORT it, do not
fix it in this round). ⛔ If any consumer RELIES on relative resolution
(behavior that would break under expansion): REPORT AND STOP — never
improvise a semantics decision inside a fix round. "None rely on it" is the
expected finding; prove it by reading, not by assertion.

## Phases — order matters

**Phase 1 — RED-FIRST, pre-fix.** `mix test
apps/commonplace_cli/test/commonplace/cli/snapshot_test.exs:<line-of-"writes a snapshot commit">
--repeat-until-failure 200`, from the WORKTREE ROOT, output to a log. STOP
AT THE FIRST RED (s3 measured red by ~rep 7 with the window open; budget one
invocation, 20 min). Capture the full body — it must show the CubDB
`{:error, :enoent}` / trigger_compaction mechanism. If NO red in the full
invocation: report that as a discrepancy and continue to Phase 2 anyway
(the fix's correctness does not depend on the demonstration, and the
post-fix class arm still binds).

**Phase 2 — the fix.** Both doors + inline comments. Compile
--warnings-as-errors. Format only touched files.

**Phase 3 — post-fix, TWO arms.** First check window state: is
`apps/commonplace_cli/tmp/test_data/commits` present? If Phase 1 created it
(the flip can happen after a red), DELETE both tmp trees
(`tmp/` at worktree root AND `apps/commonplace_cli/tmp/`) and SAY SO — a
fix round may reset its own harness state; record the ls before/after.
Then:
  ARM A (bounded green): the same recipe, TWO invocations of
  `--repeat-until-failure 200` (each to its own log, serial, port-4002
  caveat, verdict line per rep). Expect all green.
  ARM B (⭐ THE CLASS ARM, stronger): after EACH invocation, `ls` BOTH
  candidate store locations. Assert from the reads: exactly ONE
  tmp/test_data EXISTS — at the worktree root (the boot-resolved path) —
  holding boot artifacts AND commits; the app-dir copy NEVER APPEARS.
  The two-stores symptom is the mechanism's other observable; its ABSENCE
  proves the CLASS died, not just the crash.

**Phase 4 — suites, blast radius.** The change touches apps/commonplace
(application.ex, commit_store.ex). Run, each to its own log, serial:
  · `mix test apps/commonplace/test` — on-main count 3582 tests / 0 failures
    (CI verdict line at 80d6e962; 16 excluded, 1 skipped). ~17 min; budget
    30. ⚠️ Entry ① in the block below governs MUD-family reds here; your
    run's population should be 3582 — state yours.
  · `mix test apps/commonplace_cli/test` — on-main count 121 tests; the ONLY
    acceptable failure shape is entry ④'s (a snapshot-command test alone) —
    and POST-FIX even that should not fire from THIS mechanism; if it does,
    capture the body: same CubDB shape = report loudly (the fix missed a
    path), different shape = report as a new fact.
  Use `bin/cp-test-guard --min 3000 -- mix test apps/commonplace/test` form
  if you prefer; either way THE VERDICT LINE IS REQUIRED per suite.

## Acceptance — artifacts

- Phase 1 red body (or the stated discrepancy).
- The diff of both doors (unstaged; show `git diff` of the two files) with
  the inline comments visible.
- The sweep table: 8 sites, each classified, with the reads that justify it.
- Phase 3: both arms' logs + the ls records proving ONE store at the
  boot-resolved path and NO app-dir store across both invocations.
- Phase 4: both suite verdict lines with populations.
- Discrepancies with this brief; near-misses. This brief is a claim, not an
  instruction.

## Known reds

⚠️ INTERACTION: entry ④ is the very defect this round fixes. Its push-run
rules are unchanged until the fix LANDS on main (the reviewer handles the
block update with boss — not yours). Entry ① matters for Phase 4's
commonplace suite; population caveats as written there.


```
KNOWN REDS ON main (as of 80d6e962, 2026-08-18 06:30Z) — NOT YOURS. Anything else IS.

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
      ⛔⛔ THE HANDLE IS SINGLE-USE PER CHECKOUT — READ THIS BEFORE CONCLUDING
         "NOT REPRODUCIBLE". S-snapshot-mech-s2 ran 603 instrumented reps in the
         SAME worktree that fired at rep 4 and got ALL GREEN. The crash window
         CLOSES PERMANENTLY once any invocation boots at app cwd — the reproducer
         is SELF-EXTINGUISHING per checkout. (Read as a labeled guess at 06:10Z;
         CONFIRMED by s3 at 06:20Z — see below.)
         ⇒ ⭐ IF THAT READING HOLDS: use a FRESH worktree. Re-running the recipe
           on a worktree that has already been exercised produces a null that
           means "window closed", NOT "bug absent" — AND THOSE TWO ARE THE SAME
           OBSERVATION FROM OUTSIDE. This annotation exists so that a null here
           is not mistaken for a disconfirmation.
         ⇒ IT ALSO EXPLAINS THE ~30% CI RATE WITHOUT ANY NEW MECHANISM: every CI
           run is a fresh checkout, so the window is always open there.
      ✅✅ CONFIRMED 2026-08-18 06:20Z (S-snapshot-fresh-s3, artifacts 05475ffc on
         sol/s-snapshot-fresh-s3, verified on origin — 71 log files). THE LABEL
         ABOVE HAS GRADUATED: this is no longer a reading.
         OBSERVED, in a verified-FRESH worktree, the window closing LIVE:
             invocation 1  red at rep 7
             invocation 2  red at rep 1
             invocation 3  red at rep 1 — app-dir commits/ flips absent→present
             invocations 4-5  402 consecutive greens, zero compaction crashes
         MECHANISM: CubDB's State.data_dir is RELATIVE, and mix has a boot-vs-test
         CWD SPLIT. Compaction CREATES BY PATH. ⇒ NOTHING IS EVER DELETED — THE
         PATH'S MEANING MOVES. Once an invocation boots at app cwd the directory
         exists there, the window shuts, and that checkout never fires again.
         ⇒ ⭐ THE HARNESS IS NOW NEAR-DETERMINISTIC: fresh worktree ⇒ red by ~rep 7.
           A fix round has a red-first handle waiting for it.
         ⇒ ⛔ AND THIS RETROSPECTIVELY GROUNDS THE RETRACTION ABOVE: accumulation
           does not make it MORE likely — ACCUMULATION IS WHAT CLOSES THE WINDOW.
           My n=1 rule was not merely unsupported, it was backwards. Artifacts: branch sol/s-snapshot-repro-s1 @
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
   ✅ MECHANISM KNOWN as of 2026-08-18 06:20Z (above) and a fix round is plan's to
      rank — candidate is Path.expand at capture time. UNTIL THAT LANDS the entry
      stays: a known mechanism is not a fixed defect, and CI still fires at ~30%.
      ⛔ THE RE-RUN RULE IS WHAT A ROUND NEEDS FROM THIS ENTRY. Everything below
         the rate is for whoever fixes it, not for whoever trips over it.
```

# S-snapshot-repro-s1 — reproduce the CLI.SnapshotTest intermittent, capture its failure shapes

> Ruled by commonplace-plan, channel ruling 2026-08-18 (#12863), receipt @7825819
> IN THE commonplace-plan REPO (docs/plans/QUEUE.md ranking receipts).
> Base: the checkout you are standing in — branch `sol/s-snapshot-repro-s1`,
> created from origin/main at dispatch. A RELATION, not a sha.
> Work label: S-snapshot (no CX ticket exists for this flake yet — if you need
> an id and only have others from this brief, that is a gap in MY prompt; use
> "S-snapshot" and say the brief under-specified).
>
> ⛔⛔ THIS ROUND IS A MEASUREMENT. NO FIX. The failure is the subject, not a
> defect to repair. "No fix" covers: no assertion changes, no setup/teardown
> changes, no sleeps added, no test skips. It does NOT cover: running the
> existing tests as-is (expected, it is the whole round), writing NEW throwaway
> scripts/log files in the worktree, or `mix deps.get`/`mix compile`.

## Your environment (facts, so a negative finding can be attributed correctly)

- You are inside a bwrap sandbox, `--sandbox workspace-write`, workdir = this
  worktree. The network is SHARED with the host (egress open, by jes's 2026-08-07
  ruling) — the wrapper's name means "runner WITH egress", not a fence.
- ⛔ `.git` is READ-ONLY — NEVER commit. Leave all work unstaged.
- ⛔ NO contact with the live store (`/home/jes/commonplace/workspace/.commonplace/commits/`
  — workspace-relative, NOT repo-root, NOT `data/`) and NO contact with any
  running serve. Nothing in this round needs either.
- ANYTHING MEASURED INSIDE THE FENCE INHERITS THE FENCE AS A FACT: masked
  paths and absent credentials surface as ordinary negative findings with
  plausible mechanisms attached. If a result smells like the sandbox rather
  than the code, REPORT the suspicion instead of concluding.
- A fresh worktree may need `mix deps.get` before anything boots.

## The subject — every count with its selector

- File: `apps/commonplace_cli/test/commonplace/cli/snapshot_test.exs`.
  THREE tests (selector: `grep -c '    test "' <file>` → 3), one describe block
  "snapshot command":
    A. "writes a snapshot commit for the resolved doc"
    B. "writes a snapshot for the root schema when no path is given"
    C. "returns :path_not_found when the path does not resolve"
- CI observations (push runs on main, read from run logs, 2026-08-16..18):
  the module fails ALONE — one test red, every other suite in the run green —
  in 4 of the last 11 completed push runs (~30%, rate measured by boss-clod).
  Assertion A observed red ×2 (runs @bb086a53, @80d6e962); assertion C
  observed red ×2 (runs @0bf50a30, @a2efb172). Assertion B: never observed red.
- THE ONE CAPTURED FAILURE BODY (CI run 32103343882 @80d6e962, assertion A) —
  the only body anyone has ever captured for this flake; the other three reds
  were recorded as names only:

```
** (exit) exited in: GenServer.call(Commonplace.Store.CommitStore, {:create_commit, ...}, 5000)
   ** (EXIT) an exception was raised:
       ** (MatchError) no match of right hand side value: {:error, :enoent}
           (cubdb 2.0.2) lib/cubdb.ex:1499: CubDB.trigger_compaction/1
           (cubdb 2.0.2) lib/cubdb.ex:1523: CubDB.do_compact/1
           (cubdb 2.0.2) lib/cubdb.ex:1358: CubDB.handle_call/3
   code: Commonplace.CLI.Snapshot.do_run(dir, "", ["notes.txt"])
   stacktrace:
     (elixir 1.18.4) lib/gen_server.ex:1128: GenServer.call/3
     (commonplace 0.1.0) lib/commonplace/store/commit_store.ex:674: Commonplace.Store.CommitStore.snapshot/2
```

- Facts about the file, stated as WHAT IT IS (read them yourself before Stage 0):
  · the suite uses the shared `tmp/test_data` data_dir and the APP-DEFAULT
    CommitStore process (registered name `Commonplace.Store.CommitStore`),
    not a per-test store
  · its setup RESTARTS the :commonplace app if a prior test left
    `Application.get_env(:commonplace, :data_dir)` ≠ "tmp/test_data" — and
    does nothing when the env matches, whatever the files underneath contain
  · its on_exit stash/restores the shared `root` file in tmp/test_data
- LABELED REASONING, NOT INSTRUCTION (you may come back "NOT that shape"):
  the lone-red, module-wide, multi-assertion geometry RESEMBLES
  GitBridge.ServerTest's teardown class, and the :enoent body SUGGESTS
  something removed store files mid-suite. Both are candidate readings from
  ONE captured body and an analogy. Nothing here presumes the mechanism —
  your job is to capture shapes, not to confirm these.

## The task — three stages, strictly serial, everything to log files

⚠️ STRICTLY SERIAL: never two `mix test` runs at once — load is a treatment,
and sequential runs can collide on PORT 4002 (the previous VM holds it for
seconds after its verdict line; a run that dies at boot leaves a small log
whose greps all return 0 — check the verdict line EVERY run).

**Stage 0 — baselines.** `mix deps.get` if needed; `mix compile --warnings-as-errors`
must pass. Then ONE run of the file alone, output to a file:
`mix test apps/commonplace_cli/test/commonplace/cli/snapshot_test.exs`.
Record: verdict line, seed (the "Running ExUnit with seed:" line), wall time,
`uptime` before and after. Expected 3/0 but MEASURE — if Stage 0 is red,
capture the body and that is already a result.

**Stage A — file alone, per-test repetition.** For EACH of the three tests,
one at a time (⚠️ repeat-until-failure STOPS at the first failure, so running
tests together lets one mask another — hence per-test):
`mix test <file>:<line-of-test> --repeat-until-failure 200`
Budget: 200 reps or 15 minutes per test, whichever first — if you stop at a
time budget, STATE the actual rep count reached. For every invocation record
the seed line(s). ⭐ REPORT WHETHER THE SEED IS HELD FIXED ACROSS REPS within
one --repeat-until-failure invocation — read it from the output, and if the
output only prints a seed once, say exactly that (what was observable, not
what you infer). If the seed IS fixed and reds still occur, say so explicitly
in the report — it is a discriminator (arrangement excluded for this flake).

**Stage B — whole cli app, repeated runs.** The CI reds occur in full-app runs
(121 tests at 80d6e962 per CI's verdict line — measure your own in-sandbox
count). Loop: `mix test apps/commonplace_cli/test`, each run to its OWN log
file, 30 runs or 45 minutes whichever first (state the actual count). After
each run: verdict line present? any failure → capture the FULL error body +
seed + which test. `uptime` snapshot at stage start/end.

## The escape hatch — pre-declared, bounded

"COULD NOT REPRODUCE at the stated bounds" IS A RESULT, not a failed round.
Report it as: per-stage rep/run counts actually executed, seeds observed,
loadavg range, zero failures — and stop there. That null is informative on
its own: CI shows ~30% per full-suite push run; a sandbox null at these
bounds makes the flake environment- or population-dependent, which is a
finding. ⛔ Do NOT keep escalating rep counts past the budgets to force a
red, and do NOT manufacture one (no killing stores, no deleting files —
provocation is a DIFFERENT round).

## Acceptance — artifacts either way

EITHER: at least one reproduced failure, reported as the FULL verbatim error
body + test name + seed + stage + rep number + the log file path that holds it.
Compare AGAINST the captured CI body above: SAME shape / DIFFERENT shape /
partially matching — say which, quoting the differing lines.
OR: the bounded null in the escape-hatch form.
PLUS in both cases: the Stage 0 baseline block, the seed-holding answer from
Stage A, per-stage uptime snapshots, and any discrepancy between this brief
and what you find (THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION — report where
it is wrong). Report the near-miss too.

Nothing in this round needs live-serve verification; if you believe something
does, mark it UNVERIFIED and stop rather than reaching for the serve.

## Suites and known reds

The only suite this round runs is `apps/commonplace_cli` (file-scoped in
Stages 0/A, app-scoped in Stage B). On-main count: 121 tests / 1 failure at
CI run 32103343882 @80d6e962 (that 1 = the subject of this round). This round
ADDS NO TESTS, so the arrangement caveat applies only as: your in-sandbox
population may differ from CI's — state yours.

⚠️ INTERACTION NOTE, read before the block: entry ④ below is ABOUT THE VERY
TESTS THIS ROUND TARGETS. Its "re-run before investigating / not yours" rule
governs PUSH RUNS on main. In THIS round a SnapshotTest red is the
DELIVERABLE — capture it, never discard it under ④. The block is pasted whole
because the rule is "paste the block", not "paste the relevant part".


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
   ⛔ NOT "STANDING" AND NOT A TRIGGER — it fires at a rate and no action of yours
      summons it. If your push goes red ONLY here, RE-RUN BEFORE INVESTIGATING:
      at ~30% a single red carries almost no information.
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

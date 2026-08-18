# m0qw-audit-m1 — the capture-loss mechanism, MEASURED (a measurement round: no fixes)

> Ticket: CX-m0qw (tix, open, read from the live store 2026-08-18):
> "Trust audit path was ALIVE AND BLIND: 102/102 canary green while
> ~148,642 organic denials went unrecorded (5 of 148,647 captured)".
> Ranked head-of-lane by commonplace-plan 2026-08-18 (#12974).
> Base: this worktree — branch `sol/m0qw-audit-m1` from origin/main.
> A RELATION, not a sha.
> Work label: AUDIT-M1 AND NO OTHER ID.
>
> ⭐ ROUND SCOPE — M1 of 2, AND IT IS A MEASUREMENT ROUND. Plan's ruled
> law, binding here: "a measurement round that fixes what it measures
> stops being a measurement." This round REPRODUCES the loss, NAMES the
> mechanism, and produces the red-first number (ticket arm #3). It does
> NOT fix anything: no production-code changes AT ALL — lib/ is
> read-only to you by policy (test/, scripts in the worktree root, and
> this report are your write surface). M2 (the fix + the
> restart-surviving loss invariant + the log-sink timestamp fix) builds
> against what you name.
>
> ⭐ THE BRIEF IS A CLAIM, NOT AN INSTRUCTION. If the code contradicts a
> line here, the code wins and the discrepancy goes in your report.
> ⛔ AND THE TICKET'S OWN GUARD IS THE ROUND'S LAW: "Do not close this
> by finding *a* plausible mechanism — find the one that predicts 5."
> A mechanism you cannot make reproduce a catastrophic capture rate is
> not the mechanism, however good the story.
>
> ✅ AN HONEST NEGATIVE IS A COMPLETE, GOOD OUTCOME: if HEAD's code
> cannot be made to lose records at anything like the measured rate,
> say so with the harness that failed to reproduce it, and pivot the
> round to ARCHAEOLOGY: identify what the code looked like during the
> measured boot (the boot ended 2026-08-07 23:41:56; `git log
> --until=2026-08-07 -- apps/commonplace/lib/commonplace/trust/` finds
> the as-of state), and name which subsequently-landed change closed
> the window, with the discriminating diff. "Fixed incidentally by X,
> reproduce confirmed against the pre-X tree" is a full answer.

## Your environment

bwrap sandbox, workspace-write, egress open by ruling (unneeded). ⛔ `.git`
READ-ONLY — never commit; leave all UNSTAGED. ⛔ No live-store
(`/home/jes/commonplace/workspace/.commonplace/commits/`) or serve
contact — REPRODUCE IN TEST HARNESSES ONLY; the historical serve.log and
audit doc are quoted in the ticket and below, you do not need to (and
must not) touch them. `mix compile --warnings-as-errors` must pass.
⛔ No tree-wide `mix format` — explicit paths, asserted non-empty.
Suites one app at a time, each to its own file, never piped; commonplace
needs the path-split (groups under test/commonplace/* summed + the two
stragglers test/commonplace_test.exs and test/mix/).

⚠️ **THE FENCE MASKS THE LIVE WORKSPACE'S NODE SIGNING KEY (CX-cj59) —
and this round is trust code, so read this twice.** The mask renders the
live workspace's `node_signing_key` as 0 bytes but READABLE (not an
error): against the LIVE/default data dir, `with_local_node_trust`'s
best-effort fold silently skips, the anchor set is EMPTY, and every
chain fails `:untrusted_root` — an artifact of the mask, not a finding.
Consequences for you: every harness MUST mint its own keys in
test-owned tmp `data_dir`s (the existing audit tests already do —
mirror `AuditEnforceEtiologyTest`'s setup); and note the audit write
path SIGNS with the node context, so a harness with a masked/absent
node identity will count `failed` for a reason that is YOUR FIXTURE,
not the mechanism. Distinguish those before attributing.

## The measured facts you are explaining (from the ticket, verbatim where quoted)

```
BOOT 436abd78f6e73c54 (08-06 22:11 .. 08-07 23:41, ~25.5h — the process
that wrote serve.log):
  serve.log:            148,647 lines "DENIED by trust gate"
                        134,507 of them doc_uuid=6fd72a7f… (workspace ROOT SCHEMA)
                        123 lines mentioning the canary doc
  audit doc, that boot: 107 records = 102 canary + 5 organic
  ⇒ organic capture 5/148,647 = 0.003% · canary capture 102/123 = 83%
  AuditDispatcher.status/0 on the LIVE boot: 155 offered / 155 recorded
  suppression summaries in the ENTIRE doc: ONE (live boot, suppressed: 5)
```

The constraint surface any mechanism must satisfy, ALL FOUR AT ONCE:
1. destroys high-frequency events (0.003%) while PRESERVING low-frequency
   ones (83%) — a ~25,000× selection factor;
2. leaves the dispatcher's own accounting CLEAN (offered == recorded —
   the dispatcher never saw the lost events; loss is UPSTREAM of
   `AuditDispatcher.offer/2`);
3. emits (almost) NO rate-limit suppression summaries while ~148k events
   go missing — the reporting mechanism for suppression reported
   nothing;
4. emission is 1:1 BY CONSTRUCTION (Logger.warning and
   :telemetry.execute on adjacent lines of ONE unconditional clause,
   commit_store.ex `handle_local_write_denial`) — so the events FIRED.

## The terrain (verified at HEAD — read these files first)

- `trust/audit_log.ex` (580 lines): telemetry handler. Stages, in order:
  `recursion_guard/1` → `rate_gate/1` (@cap 20 / @window_ms 60_000, PER
  EVENT NAME token bucket; summary record written on window rollover
  with suppressions) → build → `AuditDispatcher.offer/2`. The handler
  catches ALL crash classes (`kind, value ->` — the CX-t3xv lesson: an
  uncaught exit makes :telemetry PERMANENTLY DETACH the handler; the
  catch-all + `handler_failure/2` exists so that cannot happen AT HEAD).
  `attach/0` / `detach/0` / `attached?/0` exist; attach happens at app
  start.
- `trust/audit_dispatcher.ex` (537 lines): bounded queue @max_queue 256,
  batch @max_batch 64, flush 250ms; shed is COUNTED + logged + telemetry;
  status/0 sums offered == recorded + shed + failed + guarded + queued +
  in_flight; writes signed with the node context via RedLog.
- `trust/audit_log_counter.ex` (CX-rp33, landed @7e283f14 — YOUR
  INSTRUMENT, this is what it was built for): per-stage atomics —
  entered / built / guarded / rate_suppressed / offered / handler_failed
  / offer_events, with the stage identity
  `entered == guarded + rate_suppressed + offer_events + handler_failed`.
  ⚠️ Per-boot BY DESIGN (persistent_term + boot_id) — fine for a harness,
  useless across restarts; that gap is M2's arm, not yours.
- `trust/denial_counter.ex`: boot_id source.
- Historical: `AuditEnforceEtiologyTest` — the existing harness idiom for
  driving real denials through the real pipeline; mirror its setup.

## What M1 produces (acceptance)

① **THE RED-FIRST NUMBER (ticket arm #3):** a harness that drives
  organic-shaped denial load through the REAL pipeline (real
  handle_event, real rate gate, real dispatcher — fixture store and
  keys; the shape that matters: sustained high-frequency denials on ONE
  doc, mixed with a low-frequency second stream standing in for the
  canary) and REPORTS capture per stage from the rp33 counters plus the
  dispatcher's status/0. The deliverable is the NUMBER at HEAD: N driven,
  M captured, per-stage deltas locating every loss. If HEAD loses, this
  is the red that M2's fix must flip — state it as `driven=…
  captured=… lost_at_stage=…`. If HEAD does not lose, that is the
  honest-negative branch (header) — pivot to archaeology.
② **THE MECHANISM, NAMED AND DISCRIMINATED (ticket arm #1's first
  half):** for each candidate you consider, name the observable that
  would distinguish it, then RUN the discrimination. Candidates worth
  ruling in/out (NOT a closed list, and none is the answer until it
  reproduces): telemetry-handler detach windows (historical class —
  check `attached?/0` over the harness run; at HEAD the catch-all should
  make this impossible: SHOW that); rate-gate accounting (does a
  sustained storm's suppression actually produce summary records? drive
  one and count summaries against the arithmetic); dispatcher shed
  (should be visible in status/0 — the live boot showed none, so if your
  harness sheds, your load shape differs from the storm's — say so);
  event-name bucketing (canary vs organic: same bucket or different?
  measure, don't read); anything upstream of `entered` (if entered <
  driven, the loss is before the handler and the candidates change).
  ⭐ THE VERDICT LINE: "the mechanism is X; it reproduces R% capture
  under shape S; it predicts the 08-06 boot's four constraints because
  …" — or the honest negative with archaeology.
③ **SELECTION-FACTOR CHECK:** whatever you name must explain the
  25,000× canary-vs-organic asymmetry. A mechanism that loses both
  streams equally is not this mechanism.
④ **NO FIX SHIPPED — verified in the diff:** `git diff --stat` shows
  test/ + worktree-root artifacts only. If during the round you SEE the
  one-line fix, write it in the report under "M2 candidate" — do not
  land it.

## Suites — blast radius

Measurement round: lib/ untouched ⇒ the gate is the commonplace app
(path-split, populations summed with exclusions) + umbrella
`mix compile --warnings-as-errors`. Your new harness runs to its own
file with its counts reported. Other apps unaffected by construction;
do not spend their wall-clock.

## Acceptance — artifacts

The per-stage capture table at HEAD (driven / entered / guarded /
rate_suppressed / offer_events / handler_failed / offered / recorded /
shed) for the storm shape AND the mixed shape · the verdict line from ②
· the selection-factor account from ③ · discrepancies with this brief
and near-misses · if honest-negative: the as-of-boot code identification
and the closing change, with its sha.

## Known reds


```
KNOWN REDS ON main (as of 42ccac75, 2026-08-18 10:50Z) — NOT YOURS. Anything else IS.

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
   Full suite CURRENT: 3603 tests, 0 FAILURES, 16 EXCLUDED, 1 SKIPPED —
   CI-VERIFIED at the GREEN row 42ccac75 (run 32127756427, read from its log).
   ⭐ THE HAND-DELTA / CI-READING SPLIT THIS LINE CARRIED FOR TWENTY MINUTES IS
      NOW CLOSED, AND BOTH HAND DELTAS WERE RIGHT: 3591 → 3601 (R2's 10) →
      3603 (the two import-deadline arms). ⇒ KEEP MAKING THE DISTINCTION ANYWAY.
      "Its author's deltas have been right every time" is a statement about the
      author, not about the next delta, and it is exactly the argument that
      stops the split being drawn on the day one is wrong.
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

④ KNOWN INTERMITTENT — THE ChatViewCompute PATHWAY. A LONE failure in a test
   that exercises ChatViewCompute, on a commit that does NOT touch that pathway.
   TWO SIGHTINGS, and they share a pathway, NOT a mechanism:
     43037955  commonplace  Chat.ChatViewComputeSupervisorTest
               "compute loop end-to-end (Anchor B)" — (MatchError) :ets.insert
               badarg on :source_doc_index, error_info cause: :id
     80925204  web          CommonplaceWebWeb.ChatRoomLiveTest
               "messages render via the generic renderer (ChatViewCompute path)"
               — assert html =~ "hello world"; the rendered <ul> was EMPTY, the
               rest of the page rendered fine
   DENOMINATOR (updated 2026-08-18 10:50Z): 2 of the last 6 push rows.
       ff071567 RED (unswept siblings — unrelated, fixed)
       bea91065 GREEN
       43037955 RED   ← family sighting 1
       6020f782 GREEN
       80925204 RED   ← family sighting 2
       9eb98e97 GREEN (S-storehelper)
       42ccac75 GREEN (import-deadline)
     ⚠️ THE TWO SIGHTINGS ALTERNATE WITH GREENS. That is an OBSERVATION about
        six rows and NOT a period — at n=2 an alternating pattern is what two
        events in six slots look like most of the time. DO NOT PREDICT THE NEXT
        ROW FROM IT. Both landings touched runner/mediator code only; both had
   green local runs; every other app was green in both rows.
   ⛔⛔ HONEST LIMIT, AND IT IS THE WHOLE ENTRY: DIFFERENT apps, DIFFERENT tests,
      DIFFERENT observables. NO SHARED MECHANISM IS PROVEN. A story exists — the
      ETS-ownership read from sighting 1 COULD produce a silently-empty render
      downstream if the compute dies and something swallows it — and it is a
      STORY. It is written here so nobody re-derives it as a finding.
   ⛔ THE BOUND, because this entry keys on a PATHWAY and that is broader than
      this file normally allows:
        · MORE THAN ONE failure in the run  ⇒ YOURS.
        · Your commit TOUCHES chat / view-compute / source_doc  ⇒ YOURS.
        · A ChatViewCompute test failing with a DIFFERENT shape again ⇒ tell me;
          a third distinct observable would mean this is a container, not a
          family, and the entry must be split or deleted.
   ⚠️ WHY IT IS AN ENTRY AT ALL AT n=2: the two rows are consecutive landings by
      the same author on code that does not touch the pathway. Without an entry
      the NEXT lander is told by our own rule that it is theirs. WITH one, they
      are told to look twice and report the shape. That is the trade, stated.
   ⏱ MECHANISM UNOWNED. The named structural candidate (:source_doc_index is a
      :named_table owned by whoever touches SourceDoc first — protection by
      accident) is plan's to rank on recurrence, not mine to assert.

```

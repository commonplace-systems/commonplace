# m0qw-audit-m2a — the zero-summaries question, MEASURED (measurement round: no fixes)

> Ticket: CX-m0qw (open). Ruled by commonplace-plan #12997 @e19b12d:
> measurement-only, same lineage as M1, three arms with ARM 1 FIRST.
> Base: this worktree — branch `sol/m0qw-audit-m1` (M1's harness and
> report are committed here @3bcd5851 — READ AUDIT-M1-REPORT.md FIRST;
> your round extends that work).
> Work label: AUDIT-M2A AND NO OTHER ID.
>
> ⭐ ROUND SCOPE — MEASUREMENT ONLY, M1's law verbatim: "a measurement
> round that fixes what it measures stops being a measurement." lib/ is
> READ-ONLY to you by policy; your write surface is test/ (extend M1's
> harness in trust/, same file or a sibling audit_m2a_*), worktree-root
> report AUDIT-M2A-REPORT.md, and nothing else. If you see the fix,
> write it in the report under "M2 candidate" — do not land it.
> ⛔ THE TICKET'S GUARD IS STILL THE LAW: do not name a mechanism that
> does not reproduce; the arithmetic picks, not the story.
> ⭐ THE BRIEF IS A CLAIM — discrepancies go in the report, not silently
> resolved.

## What M1 established (do not re-measure)

Loss site = rate gate (stage identity closes exactly; driven 148,647 →
captured 20/5). Summaries BYPASS the gate: constructed inside
`rate_gate` at rollover, offered directly (audit_log.ex:541-579), and
M1 measured one landing with suppressed=148,642. The shared-bucket
candidate is FALSIFIED for the incident (predicts a big summary; the
incident doc has zero on the storm boot). Correction on the record: the
report's "155 vs 107" discrepancy was CROSS-BOOT (107 = storm boot's
rows; 155/155 = live boot's per-boot counter; same-boot pairing
155-vs-156 = benign ±1 across read instants) — carry that pairing, do
not re-open it.

## The question this round answers

The incident: a 25.5-hour storm boot with the handler demonstrably UP
most of the boot (canary 83% captured), the gate reachable, and ZERO
suppression summaries in the doc for that boot. Whatever ate the
summaries is the incident's remaining unexplained constraint.

## The three arms, IN ORDER (plan's ruling: arm 1 is the baseline the
others are judged against)

① **MULTI-WINDOW CONTINUOUS STORM (FIRST — the baseline):** M1's mixed
  test crossed ONE window expiry and produced ONE summary. Drive a storm
  spanning N ≥ 5 window expiries at HEAD and COUNT SUMMARIES IN THE DOC
  against expected-per-window. The clock-boundary acceleration M1 used
  (backdating window_start in @rate_table) is legitimate for the WINDOW
  BOUNDARY ONLY — bucket counts and suppression arithmetic must be the
  real storm's. Deliverable: `windows_crossed=N summaries_expected≈N
  summaries_in_doc=M` with per-window suppressed sums.
  · If M ≈ N: HEAD emits per-window and the incident's zero NEEDS A
    KILLER — arm ② tests the candidate.
  · If M ∈ {0, 1}: the semantics themselves are the mechanism (e.g.
    only-on-next-event compounding across windows), no killer required —
    demonstrate WHICH semantic ate them, with the counter deltas.
② **OWNER-DEATH (the fact-B candidate, with its pre-declared tension):**
  @rate_table is whereis→new FIRST-CALLER-OWNED public ETS
  (audit_log.ex:525-535); telemetry handlers run in the emitting
  process, so the owner is whichever process fired the first denial.
  Arrange ownership deliberately (e.g. fire the FIRST denial from a
  disposable spawned process so IT owns the table — then the kill does
  not disturb the store), kill the owner MID-STORM, confirm table death
  (`:ets.whereis` → :undefined, then recreated on next event), continue
  the storm across further window expiries, and measure BOTH sides of
  the tension:
  · summaries: do accumulated suppressed counts vanish unsummarized?
  · organic admissions: each table rebirth opens a fresh window admitting
    up to cap=20 more — count the extra captures.
  The incident had organic=5 TOTAL (< one window's cap), which CUTS
  AGAINST frequent rebirths — the arithmetic of your measurements picks
  whether owner-death can thread zero-summaries WITHOUT over-admitting.
  Report both numbers; do not argue past them.
③ **STREAM-STOP (fact A measured):** storm, then stop the stream; the
  last window's suppressed count has no subsequent same-bucket event to
  summarize it. Assert it is never written (including after a
  DIFFERENT-bucket event fires — no cross-bucket flush), and state the
  bound: stream-death explains exactly ONE missing summary per stream,
  never ~1,500.

## Your environment

bwrap sandbox, workspace-write. ⛔ `.git` READ-ONLY — never commit; leave
all UNSTAGED. ⛔ No live-store
(`/home/jes/commonplace/workspace/.commonplace/commits/`) or serve
contact — the incident artifacts are QUOTED above and in the ticket; you
never touch them. `mix compile --warnings-as-errors` must pass. ⛔ No
tree-wide `mix format` — explicit paths, asserted non-empty. Suites: the
commonplace app only (measurement round, lib/ untouched), path-split
under test/commonplace/* with populations SUMMED + stragglers
(test/commonplace_test.exs, test/mix/) — ⚠️ and when you sum, remember
M1's own defect: a summary line can read "5 doctests, 468 tests,
1 failure" — parse EVERY line shape (doctest prefixes, "1 test,"
singular) and keep the per-entry logs; your predecessor's sum silently
dropped 468 tests AND A RED through an anchored regex.

⚠️ **THE FENCE MASKS THE LIVE WORKSPACE'S NODE SIGNING KEY (CX-cj59) —
trust code, read twice.** The mask renders the live workspace's
`node_signing_key` 0-byte-readable: against the LIVE/default data dir
the anchor set is EMPTY and everything fails `:untrusted_root` — a mask
artifact, not a finding. Every harness mints its own keys in test-owned
tmp data_dirs (M1's setup does this and asserts the mint succeeded —
reuse it verbatim); a `failed` count from a masked/absent identity is
YOUR FIXTURE, not the mechanism.

## Acceptance — artifacts

AUDIT-M2A-REPORT.md with: arm ① table (windows/expected/found +
per-window suppressed) · arm ② both sides of the tension with numbers ·
arm ③ the bound stated · the verdict line — either "the incident's
zero-summaries is explained by X, reproduced" or the honest split of
what each arm ruled in/out · commonplace suite verdict with populations
summed from per-entry logs kept on disk · `git diff --stat` showing
test/ + report only · discrepancies and near-misses.

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

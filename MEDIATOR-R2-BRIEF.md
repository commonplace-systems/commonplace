# mediator-pod-r2 — the relay, the pod wiring, and the posture that arrives with its mechanism

> Ruled by commonplace-plan: pod-model-credential spec §7 (`23578db`,
> commonplace-plan repo — quoted below where binding) + R1 ratification
> @939590c. R1 LANDED at `43037955` (this worktree's base): read
> `apps/commonplace/lib/commonplace/runner/mediator.ex` and its test file
> FIRST — R2 builds against that real, landed interface.
> Base: this worktree — branch `sol/mediator-pod-r2` from origin/main.
> Work label: MEDIATOR-R2 AND NO OTHER ID.
>
> ⛔⛔ THE SAME-COMMIT CONSTRAINT, verbatim from the spec and binding on YOUR
> commit-shape (you never commit; it binds what must land TOGETHER — keep it
> ONE coherent diff): "The PodProfile closed set widens to admit
> 'mediator-socket' IN THE SAME COMMIT as this mechanism — the refusal test
> changes deliberately, as written @b01d9873." The vocabulary and the
> mechanism are one change. Do not stage a world where the name exists
> without the argv that implements it.

## Your environment

bwrap sandbox, workspace-write, egress open by ruling (not needed — every
endpoint in tests is local). ⛔ `.git` READ-ONLY — never commit; leave all
UNSTAGED. ⛔ No live-store (`/home/jes/commonplace/workspace/.commonplace/commits/`)
or serve contact. `mix compile --warnings-as-errors` must pass. ⛔ No
tree-wide `mix format` — explicit path lists only, ASSERTED NON-EMPTY.
⚠️ POD TESTS IN-SANDBOX: you are inside bwrap; the suite's pod tests spawn
bwrap NESTED. If a pod-spawning arm fails with a bwrap/namespace error
(not a code error), capture the EXACT stderr, mark that arm UNVERIFIED, and
continue with the arms that do not spawn pods — the reviewer runs
UNVERIFIED arms outside. ⛔ A bwrap capability error and a code defect must
never be conflated; the error text discriminates, quote it.

## The seams, verified at HEAD (read each before editing)

- `apps/commonplace/lib/commonplace/runner/pod_profile.ex`:
  `@network_postures ~w(none)` — the closed set; its comment already names
  "mediator-socket" as the ruled next member arriving with its mechanism.
- `apps/commonplace/test/commonplace/runner/pod_profile_test.exs` (~line
  40): THE test that flips deliberately — today it asserts
  `"mediator-socket"` is REFUSED; your change makes the name valid at the
  profile layer. Keep a refusal test for a genuinely-unknown posture (e.g.
  "open") — the closed set stays closed to everything unruled.
- `apps/commonplace/lib/commonplace/runner/provisioner.ex`:
  `supported_network/1` ("none" ⇒ :ok, else refused: "a posture must never
  be a label the argv does not implement") and the base argv builder
  (`--unshare-all` around line 117). The mediator-socket mechanism lives
  HERE: same isolation as "none" PLUS exactly one
  `--bind <socket_path> <socket_path>` PLUS the in-pod relay wired into the
  pod's command. Pod-internal loopback is measured USABLE inside
  `--unshare-all` (CI arm 4 + both machines) — the relay binds
  127.0.0.1:PORT inside the pod netns.
- `apps/commonplace/lib/commonplace/runner/mediator.ex` (landed R1): the
  host side your wiring talks to. Its socket paths are start parameters;
  its token format is base64url(JSON{deployment_id,expires_at}).sig —
  `Mediator.mint_token/3` exists. ⚠️ `Commonplace.Crypto.Signing` has NO
  generic sign/verify; R1 uses raw
  `:crypto.sign(:eddsa, :none, payload, [key, :ed25519])` — match it.
- Bandit unix-socket listeners need `port: 0` beside `ip: {:local, path}`
  (R1's measured discrepancy, carried).

## The parts, from §7 (quoted where binding)

**IN-POD RELAY** — "TCP 127.0.0.1:PORT → the bound socket. A byte pipe.
Holds no credential, no policy, no decisions. It exists only because
codex's base_url is TCP-only (measured)." ⇒ It must run INSIDE the pod's
network namespace (a host process cannot serve the pod's loopback). HOW it
is packaged and spawned inside the pod is YOUR design within the
provisioner's idioms — candidates include wrapping the pod command to start
the relay before exec'ing the payload, or a small escript — REPORT the
choice and why. Constraints regardless of packaging: bytes both directions,
no parsing, no credential in its environment or argv, and its death must
not be silent (see the loud-failure arm).

**POD WIRING** — posture `"mediator-socket"` ⇒ the argv above. The
deployment's socket path and relay port reach the pod through the same
declared-configuration channels the launcher already uses (read how the
launcher passes structured config today and match it; if nothing fits,
propose the smallest addition and REPORT it). The spec's client-side shape,
for context only (R2 does NOT configure codex): the pod's client selects
`base_url=http://127.0.0.1:PORT`, env_key = the pod token.

## Acceptance arms — §7's list, red-first, both directions

① **ABSENCE (posture "none"):** a pod launched with posture "none" has NO
  socket bound and cannot reach a mediator AT ALL — assert the absence
  (the bind is not in the argv; in-pod, the socket path does not exist).
② **THE FLIP:** profile-layer: "mediator-socket" validates; unknown
  posture "open" still refused by name. Provisioner-layer: the
  mediator-socket argv contains exactly ONE --bind of the socket path and
  retains the same namespace isolation as "none"; red-first — before your
  mechanism exists, the posture is refused (that is today's state; capture
  it, then flip).
③ **REVOCATION IS SURGICAL:** two deployments, one mediator (R1 supports
  this — see its counting test); revoke deployment A's token; A's requests
  refuse BY NAME while B's continue succeeding. (This arm is host-side —
  no pod spawn needed; drive it through the relay if pods work in-sandbox,
  through TCP-to-socket directly if not, and SAY which.)
④ **THE RELAY HOLDS NOTHING:** "its environment and filesystem enumerated
  in-test" — whatever packaging you chose, the test enumerates the relay
  process's environment (and argv) and asserts no credential material is
  present (the pod token is the CLIENT's to send, not the relay's to hold).
⑤ **LOUD DEATH:** kill the mediator; a pod request through the relay fails
  LOUDLY with a named error surfaced to the caller (launcher repeats the
  pod's words) — never a silent hang. Bounded time asserted.

## What R2 does NOT do

⛔ No codex configuration, no CODEX_HOME, no live vendor — the
terminal-shape measurement (which refusal statuses the real client treats
as terminal) is being run HOST-SIDE by the reviewer in parallel; if its
result demands a status re-map, that lands as a follow-up, not here.
⛔ No changes to mediator.ex's verification/refusal/counting semantics
(plan ruled the arrival-counter stays as-is; a separate verified-forwards
counter arrives with the receipts design, NOT now).
⛔ No launcher-unrelated refactors.

## Suites

Blast radius: apps/commonplace/lib touched ⇒ ALL FIVE apps (the rule:
suites derive from the DIFF's consumers, not the edited dir). On-main at
43037955: commonplace 3591/0/16/1 · cli 121/0 · bots 276/0 · mcp 158/0 ·
web 136/0. Run each TO ITS OWN FILE and grep the file — never pipe a
mix test. Verdict line per suite; state populations and deltas by hand.
Pod-spawning suites in-sandbox: the UNVERIFIED protocol above.

## Known reds


```
KNOWN REDS ON main (as of ff071567, 2026-08-18 07:45Z) — NOT YOURS. Anything else IS.

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

```

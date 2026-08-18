# mediator-core-r1 — the host mediator process: custody, verification, streaming passthrough

> Ruled by commonplace-plan: `docs/plans/2026-08-17-pod-model-credential.md` §7
> (`23578db` IN THE commonplace-plan REPO — you cannot read that repo from the
> sandbox; every §7 requirement this round needs is quoted below, and if a
> quoted requirement seems to contradict the code you find, REPORT it).
> Base: this worktree — branch `sol/mediator-core-r1` from origin/main.
> A RELATION, not a sha.
> Work label: MEDIATOR-R1 AND NO OTHER ID.
>
> ⭐ ROUND SCOPE — R1 of 2, and the split is deliberate: THIS round builds the
> HOST MEDIATOR process and its unit-level arms only. The in-pod relay, the
> pod wiring, and the PodProfile "mediator-socket" posture widening are R2 —
> and the spec's same-commit constraint ("the closed set widens IN THE SAME
> COMMIT as this mechanism") binds R2's pieces to EACH OTHER, not R1 to R2.
> ⛔ Do NOT touch PodProfile, the launcher, or any posture/closed-set code in
> this round. No relay either.

## Your environment

bwrap sandbox, workspace-write, egress open by ruling (you will not need it —
the vendor in every test is a LOCAL fake). ⛔ `.git` READ-ONLY — never
commit; leave everything UNSTAGED (the reviewer lands). ⛔ No live-store
(`/home/jes/commonplace/workspace/.commonplace/commits/`) or serve contact.
`mix deps.get` (hex cache write failure non-fatal if compile passes);
`mix compile --warnings-as-errors` must pass. ⛔ No tree-wide `mix format` —
format ONLY files you touched, BY EXPLICIT PATH LIST, and if you build that
list with a command substitution, ASSERT IT IS NON-EMPTY FIRST (an empty
list makes `mix format` tree-wide; it bit the reviewer tonight, 322 files).

## The component, from §7 (quoted requirements — the shape is binding)

**One process, `Commonplace.Runner.Mediator`** (home: the existing
`apps/commonplace/lib/commonplace/runner/` — launcher, pod_profile,
provisioner and friends live there; match their idioms). It:

- Holds the vendor credential pair (access + refresh) — "custody NEVER
  enters any pod." In R1 the pair arrives via start opts; where production
  loads it from is R2/ops, NOT this round.
- Listens on ONE PATHNAME UNIX SOCKET PER DEPLOYMENT:
  spec path shape `/run/cp/pod-<deployment_id>/mediator.sock`, but THE PATH
  IS A START PARAMETER and every test uses a tmp dir — nothing in this round
  writes /run.
- Per request, in order: ① identify the caller BY THE SOCKET THE REQUEST
  ARRIVED ON ("granted by the mount namespace, unforgeable by the pod") ·
  ② VERIFY the pod's ephemeral deployment-principal token ("belt and braces
  from different suppliers — the token is what gets verified, the socket is
  what gets addressed") · ③ forward `POST /v1/responses` to the vendor under
  the mediator-held ACCESS token, refreshing mediator-side.
- **Streams the SSE response back UNBUFFERED** — "accept: text/event-stream
  is in every request — buffering breaks the client's read loop; the body
  streams through as bytes, never parsed."
- **Socket-identity vs token-identity mismatch ⇒ refuse** — "the §4f
  integrity rule (same channel, different principal) arriving at runtime."
- **Wrong or revoked token ⇒ named refusal, never a hang. Vendor
  unreachable ⇒ named refusal.** ⚠️ "Error semantics feed a client that
  WILL hammer — 5 rapid retries observed — so a refusal must be
  terminal-shaped, not retriable-shaped, or one bad token costs 5×."
  KNOWN-UNKNOWN, stated: WHICH statuses the real client treats as terminal
  is unmeasured. Implement refusals as distinct 4xx with a JSON body naming
  the refusal; the live retry-behavior measurement is R2's. Do not claim
  terminal-shape proven.
- **Per-deployment request counting from day one** — "one line at the choke
  point"; a counter readable in tests (telemetry event or counter fn).
- ⛔ **PROMPT EXFILTRATION IS NOT SOLVED AND NOT CLAIMED SOLVED. This goes
  INLINE in the mediator's source with its reason** — a comment at the
  forwarding site stating: a mediator is a bidirectional channel and cannot
  judge prompt content; the residual is accepted and named here.

## Facts I verified at HEAD (selectors included) — build on these

- `bandit 1.10.3` and `plug 1.19.1` are ALREADY in the umbrella `mix.lock`
  (via commonplace_web/phoenix) — adding `{:bandit, "~> 1.0"}` (+ plug if
  needed) to apps/commonplace's deps introduces NO new package, only a new
  edge to already-locked versions. Bandit listens on unix sockets via
  thousand_island's `ip: {:local, path}`. Use it for the server side; do NOT
  hand-roll an HTTP parser.
- `req 0.5.x` is already a core dep — vendor-side client; it supports
  response streaming (`into:` fun/collectable). The vendor client must
  stream, not accumulate.
- Ed25519 exists: `Commonplace.Crypto.Signing` (generate_keypair, sign,
  verify — read the module; the trust layer uses it everywhere). The
  deployment-principal token in R1 = a signed payload verifiable with a
  public key the mediator is configured with. Match the codebase's existing
  token/cert idioms where one fits (grep `Signing.` call sites); if none
  fits cleanly, a minimal signed {deployment_id, expiry} payload is
  acceptable — SAY which you did.
- The measured client behavior your fake must serve (from the discharged §7
  measurement, quoted): requests arrive as `POST /v1/responses` ·
  `accept: text/event-stream` · `authorization: Bearer <env_key value,
  VERBATIM>`. Your FAKE VENDOR in tests: a local Bandit listener on
  127.0.0.1 ephemeral port that records requests and emits scripted SSE.

## Acceptance arms — red-first where a gate is involved (both directions)

① PASSTHROUGH: valid token on deployment A's socket → the fake vendor
  receives the POST with `authorization: Bearer <ACCESS token>` (the
  mediator's, NOT the pod token) and the request body byte-identical; the
  SSE events stream back. ⭐ THE UNBUFFERED PROOF: fake vendor emits event 1,
  WAITS for a signal, then emits event 2 — the test must observe event 1
  on the client side BEFORE releasing the signal. A mediator that buffers
  cannot pass this arm.
② REFUSALS, each by name, each red-first (the dangerous answer CANNOT):
  a. garbage token → named refusal; the fake vendor received NOTHING
     (assert zero vendor requests — the refusal is BEFORE forwarding).
  b. valid-signature token for deployment B arriving on deployment A's
     socket → the mismatch refusal, named; vendor untouched.
  c. expired token → named refusal; vendor untouched.
  d. vendor down (fake stopped) → named refusal, not a hang (bounded time).
③ REFRESH: fake vendor 401s the first forward; the mediator refreshes
  against the fake's refresh endpoint, retries ONCE with the new access
  token, succeeds; the refreshed pair is used for the NEXT request too
  (state persists). A second 401 after refresh ⇒ named refusal (no loop).
④ COUNTING: after N requests on deployment A and M on B (A, B = two
  sockets, one mediator), the per-deployment counts read N and M.
⑤ NO CATCH-ALL: any request shape other than POST /v1/responses ⇒ refused
  BY NAME (unmapped ⇒ refused, never default-forwarded).

Escape hatch, pre-declared and bounded: if Bandit's unix-socket listener
does not work in this environment (measure it FIRST — a 5-line listener
probe before building anything on it), REPORT the probe's actual error and
STOP the server half; deliver the verification/refusal/counting core with
its arms driven through a direct function interface instead, and say so.
That is a partial result with a named gap, not a failed round. ⛔ What it
does NOT license: skipping arms that don't depend on the socket.

## Suites — name them with their on-main counts

- New tests live in `apps/commonplace/test/commonplace/runner/` beside the
  existing runner tests. Full app: `mix test apps/commonplace/test` —
  on-main 3582 tests / 0 failures / 16 excluded / 1 skipped (measured at
  ff071567, local landing gate). Your run adds your new tests — state your
  population and the delta BY HAND.
- deps change ⇒ compile ALL apps `--warnings-as-errors` from umbrella root.
- Verdict line required per suite run; redirect to files and grep the file;
  sequential runs collide on port 4002.

## Known reds

⚠️ The block below is current as of `1bd07c2` — CLI.SnapshotTest was RETIRED
from it tonight (fixed on main at ff071567); a SnapshotTest red anywhere in
your runs is a REGRESSION and must be reported loudly, not excused.


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

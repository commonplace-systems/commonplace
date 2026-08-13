# Tix status reconciliation — 2026-08-13

Scope: the 43-ticket export in `tix-reconcile-targets.md`, exported
2026-08-13T15:03:33Z: 15 `open` + 28 `in_progress`. The open population was
graded on whether its stated condition is met. The `in_progress` population
was graded only on whether anyone is on it; every exported row says
`claimed_by=nil`, so unfinished work is never closed merely because its claim
is stale.

## Verdict table

| ticket | stated condition (from the ticket) | artifact examined | verdict | evidence / what was checked |
|---|---|---|---|---|
| CX-vvbh | Make missing, unreadable, and zero-key local public-key outcomes loud and distinct; keep healthy self-trust quiet; correct the stale comment. | `dc72b204:apps/commonplace/lib/commonplace/trust.ex:1174`; test `Commonplace.Trust.SelfTrustVisibilityTest` at `dc72b204:apps/commonplace/test/commonplace/trust/self_trust_visibility_test.exs:35` | **CLOSE** | The implementation logs separate identity, `:absent`, `{:error, reason}`, and `{:ok, []}` degradations at lines 1186–1222; tests cover absent, unreadable, zero-key, identity failure, and the quiet healthy control (lines 35–110). This is a fixed bug. |
| CX-q9sa | Prevent any test from recursively deleting the boot-captured live singleton CommitStore directory or its contents; assert at deletion time and include a positive control. | `6741a216:test/support/file_rm_rf_guard.exs:22`; tests `Commonplace.FileRmRfGuardTest` at `6741a216:apps/commonplace/test/commonplace/file_rm_rf_guard_test.exs:6` | **CLOSE** | The suite-wide `File.rm_rf/1` and `rm_rf!/1` shim checks both ancestor and descendant overlap against the live CubDB handle (lines 22–73, 123–130). Positive controls refuse the directory and a real child file; negative controls permit a sibling and an owned temp directory. Later phase-a measurement ran 4,352 tests per seed (`b40fd252:docs/plans/2026-08-11-ci-red-enumeration-measurement.md:3`). This is a fixed bug. |
| CX-1jh2 | Preserve configured fallback for `:absent`, make corrupt public-key artifacts loud, and apply one outcome policy at both Trust and MUD consumers. | `ba964896:apps/commonplace/test/commonplace/trust/public_anchor_artifact_test.exs:134`; test `Commonplace.Trust.AnchorConsumerPairTest` at `ba964896:apps/commonplace/test/commonplace/trust/anchor_consumer_pair_test.exs:4` | **CLOSE** | Tests distinguish absent from zero, prove absent fallback, and make corrupt-anchor loss loud (lines 134–224); the pair test proves MUD delegates to `Trust.anchor_keys/1` and no longer calls `NodeIdentity.public_keys/0` itself. This is a fixed bug. |
| CX-b38c | Rule how an attenuated cell principal can author code within its granted subtree before L2. | `1259d06d:docs/plans/2026-08-10-cell-demo-slice-decomposition.md:68` | **STAY-OPEN** | The ruling preserves the write-perp-execute belt, rules out runner-as-author, and chooses an explicit-capability destination shape, but line 85 explicitly says the mechanism round is still owed before L2. The condition is therefore only partially met; the commit subject was not closure evidence. |
| CX-fm7x | Replace everything-minus-four sync with a declared scope policy in which imports are enumerable from the pin and exclusions are declared, never inferred. | `a164fa76:apps/commonplace_cli/lib/commonplace/cli/proto_chit.ex:7`; `df7df185:docs/notes/2026-08-11-cell-demo-full-world-evidence.md:8` | **STAY-OPEN** | The code adds repeatable operator exclusions without dropping defaults (lines 7–29, 70–77), and the full-world run proves two declared secret exclusions plus four defaults and per-file pin enumeration (lines 17–22, 69–74). But the ticket itself calls this an interim operator mechanism “NOT the policy”; no general allowlist/gitignore/manifest policy artifact was found. |
| CX-5gkw | Replace inherited wall-clock budgets for the four non-instrument victims with explicit, sized budgets while leaving the AuditChoke ratio budget untouched. | `5ca502c2:apps/commonplace/test/commonplace/green/bursar_test.exs:479`; `295e3ead:docs/plans/2026-08-11-ci-red-classification.md:7` | **CLOSE** | The four affected test files receive explicit budgets with workload bases; e.g. Bursar keeps the size assertions and marks I/O-heavy loops at lines 479–553. The later measured pipeline found all former pool members green in three 4,352-test runs, with the sole local red unrelated (classification lines 9–11). This is a fixed test-instrument defect, not merely an audit title. |
| CX-e2vk | Determine why the same seed and invocation yield different failure sets, and retire order/file-bisection attribution if the variable is timing. | `b40fd252:docs/plans/2026-08-11-ci-red-enumeration-measurement.md:3`; `295e3ead:docs/plans/2026-08-11-ci-red-classification.md:7` | **CLOSE** | Phase A measured three equal 4,352-test populations (seeds 101/202/303); phase B found the former rotating pool gone and classified the sole local red as deterministic environment invalidation. The question is answered/superseded: the earlier order theory is retired; this is not being recorded as a production bug fix. |
| CX-evy4 | Answer whether the “flaky pool” is one mechanism or multiple mechanisms. | `295e3ead:docs/plans/2026-08-11-ci-red-classification.md:7` | **CLOSE** | The later classification explicitly says the population is not a pool, reports the suite-reliability arc landed, and separates the remaining identities (lines 9–18, 21–51). This closes an answered question; it does not endorse the ticket’s interim “three mechanisms” taxonomy, which the later budget audit corrected. |
| CX-s4wh | Test whether `--max-cases 1` collapses the spread, then audit each victim’s time-vs-work budget. | `5ca502c2:apps/commonplace/test/commonplace/green/bursar_test.exs:479`; `b40fd252:docs/plans/2026-08-11-ci-red-enumeration-measurement.md:3` | **CLOSE** | The serial-arm question was answered “no”; the follow-on budget work is embodied in explicitly sized victim tests, and Phase A’s equal-denominator runs show the old spread absent. This is an answered measurement question plus test-instrument changes, not a claim that serialization fixed anything. |
| CX-vm8m | Determine what reddens the isolated-green victims, accepting “no reproducible neighbour” or an unreadable mechanism as legitimate answers. | `295e3ead:docs/plans/2026-08-11-ci-red-classification.md:7` | **CLOSE** | The later measured population contains none of those victims: everything except one unrelated deterministic invalidation is green across three umbrella runs. The durable answer is that no culprit neighbour survived the budget/fixture fixes; this closes an answered attribution question, not a bug fix. |
| CX-895n | Serve as the current “START HERE” state/ranking pointer for the suite-reliability work. | `295e3ead:docs/plans/2026-08-11-ci-red-classification.md:7` | **CLOSE** | The later classification says the arc landed, the old red-by-run rule is stale, and identifies residuals under their own tickets (lines 9–18, 40–58). The dated pointer is no longer current; live residuals remain independently tracked. |
| CX-wqt2 | Serve as the current “START HERE” pointer for a held deploy and the then-current main payload. | `df7df185:docs/notes/2026-08-11-cell-demo-full-world-evidence.md:80`; `295e3ead:docs/plans/2026-08-11-ci-red-classification.md:12` | **CLOSE** | Later evidence records a healthy serve at a newer revision and newer main/CI state. The 2026-08-10 deployment pointer has aged out; this retires a stale pointer, not work described by separate tickets. |
| CX-96t5 | Replace the retracted one-draw invocation-form claim with distributions and controlled, equal-population measurements. | `b40fd252:docs/plans/2026-08-11-ci-red-enumeration-measurement.md:3` | **CLOSE** | Phase A supplies three equal 4,352-test seed runs, exact commands, identities, rc/error shape, an alone run, matched totals, and explicit deviations (lines 3–21). The retracted question has been answered by measurement; no bug fix is claimed. |
| CX-d81c | Title only: make the proto-chit pin work in a `:minimal` cell and avoid reducing the failure to bare `:error`. | `tix-reconcile-targets.md:923`; `df7df185:docs/notes/2026-08-11-cell-demo-full-world-evidence.md:46` | **DUPLICATE-OF CX-tq3f** | The title and empty body are byte-for-byte equivalent to CX-tq3f’s, with no other reference in the 43-ticket export or git log. CX-tq3f survives because it was created first (20:01:24Z versus 20:01:46Z). The later artifact fixes the pin collision but explicitly retains the bare-error rider. |
| CX-tq3f | Title only: make the proto-chit pin work in a `:minimal` cell and avoid reducing the failure to bare `:error`. | `e2a6e0e:apps/commonplace/lib/commonplace/workspace_root_write_policy.ex:13`; `df7df185:docs/notes/2026-08-11-cell-demo-full-world-evidence.md:46` | **STAY-OPEN** | `__reflog` is now accepted for `:minimal`, and the rerun’s pin lands. But the evidence doc says the emitter still surfaced `emission failed: :error` and calls that a follow-up loudness defect (lines 48–60). The title-only condition is not wholly met. |
| CX-aw4r | Give safe-verb messages distinct actor and observer attribution. | `tix-reconcile-targets.md:939` | **CLEAR-CLAIM** | Exported `in_progress` with `claimed_by=nil` at line 940: nobody is on it in the 43-ticket baseline. This says nothing about completion; keep open and drop stale in-progress state. |
| CX-xe0r | Let `look`/`examine` resolve other live players as targets. | `tix-reconcile-targets.md:958` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 959); clear only the claim/status, never close the unfinished bug. |
| CX-z6ub | Provide a node-signed inherited standard-verb prototype with override rules. | `tix-reconcile-targets.md:966` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 967); no active claimant is recorded. |
| CX-hbbi | Stop plain `look <container>` revealing contents through a locked container. | `tix-reconcile-targets.md:974` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 975); clear claim, leave the defect open. |
| CX-fogy | Land the execute-safe home cert and align editable/save-time `:define_verb` gates without opening raw code. | `tix-reconcile-targets.md:982` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 983); no active claimant is recorded. |
| CX-aya0 | Move the stateless leaf verbs to node-signed doc-hosted engine modules behind Gate B. | `tix-reconcile-targets.md:990` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 991); clear claim only. |
| CX-vt9l | Build the ordered relational/search profile slices, leaving the scoped-index design call blocked. | `tix-reconcile-targets.md:998` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 999); no active claimant is recorded. |
| CX-cj3t.9 | Make `Facade.move` usable for gameplay with deliberately ruled authority semantics. | `tix-reconcile-targets.md:1014` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 1015); this dotted ID is counted independently and remains open. |
| CX-ypgf | Parse object-verb prepositions correctly and stop substring noun matches across words. | `tix-reconcile-targets.md:1022` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 1023); clear stale state, not the bug. |
| CX-hh70 | Stop `examine` appending raw puzzle state that reveals solutions. | `tix-reconcile-targets.md:1030` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 1031); no active claimant is recorded. |
| CX-vfau | Complete the bursar adoption wave, author verbs, cluster-arbiter design residual, and docs. | `tix-reconcile-targets.md:1047` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 1048); clear claim only. |
| CX-cj3t | Complete the ordered MUD improvement epic under its safe-verbs gate. | `tix-reconcile-targets.md:1055` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 1056); the epic stays open. |
| CX-uwam | Enforce per-taker key checks at the builtin take-from boundary. | `tix-reconcile-targets.md:1070` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 1071); clear claim, not feature scope. |
| CX-rmk | Build the Layer 2 MCP server over commonplace channels and CLI surfaces. | `tix-reconcile-targets.md:1078` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 1079); no active claimant is recorded. |
| CX-4u03 | Centralize child mutation and maintain laundering-free zone stamps and scoped authorization. | `tix-reconcile-targets.md:1101` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 1102); clear stale state only. |
| CX-wkau | Continue migrating compiled-in gameplay orchestration to doc-hosted engine modules while retaining the security kernel. | `tix-reconcile-targets.md:1109` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 1110); no active claimant is recorded. |
| CX-u7kj | Remove excess vertical whitespace between MUD web-console turns. | `tix-reconcile-targets.md:1117` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 1118); leave the UI bug open. |
| CX-cgs | Deliver the wiki-style LiveView demo: browse, create, edit, links, recent changes, and history. | `tix-reconcile-targets.md:1125` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 1126); no active claimant is recorded. |
| CX-mxxe | Hide full verb state and actor-ref/name mappings from ordinary `examine`. | `tix-reconcile-targets.md:1133` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 1134); clear claim, keep defect open. |
| CX-oj83 | Restore a repeatable newcomer key path so looted unique items cannot permanently dead-end onboarding. | `tix-reconcile-targets.md:1141` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 1142); no active claimant is recorded. |
| CX-hqk5 | Add safe persistent stateful mechanics without widening the verb sandbox unsafely. | `tix-reconcile-targets.md:1149` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 1150); clear stale status only. |
| CX-0t2r | Decide whether to retire serve reflog checkpointing or revive it with signing, a driver, and transient-path controls. | `tix-reconcile-targets.md:1172` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 1173); no one is recorded as working the decision. |
| CX-qat5.7 | Expose the MUD beyond localhost only after explicit human approval and with a protected transport. | `tix-reconcile-targets.md:1180` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 1181); the human-gated work remains open and unclaimed. |
| CX-73a3 | Complete the no-bypass audit routing every principal-facing read through authorization. | `tix-reconcile-targets.md:1188` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 1189); clear claim only. |
| CX-nyj9 | Support trusted spawn-from-template or same-run configuration of a freshly minted object. | `tix-reconcile-targets.md:1196` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 1197); no active claimant is recorded. |
| CX-q9aj | Smoke-test the named commonplace MCP system and dynamic-tool round trips and report findings. | `tix-reconcile-targets.md:1208` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 1209); clear stale state, do not infer the smoke test ran. |
| CX-2o9o | Surface safe-verb compile diagnostics and source lines instead of the opaque “errors have been logged.” | `tix-reconcile-targets.md:1216` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 1217); leave the unfinished bug open. |
| CX-cj3t.10 | Add a self-only/directed messaging facade primitive without arbitrary cross-player targeting. | `tix-reconcile-targets.md:1237` | **CLEAR-CLAIM** | Exported `in_progress`, `claimed_by=nil` (line 1238); this dotted ID is counted independently and remains open. |

## Counts

Baseline and denominator measured from the export: **43 = 15 open + 28
in_progress**.

| verdict | count | scope |
|---|---:|---|
| CLOSE | 11 | open population; condition met or dated/question-only item answered/retired |
| STAY-OPEN | 3 | open population; CX-b38c, CX-fm7x, CX-tq3f retain named unmet conditions |
| UNVERIFIABLE | 0 | no row required an evidence-free closure; uncertain conditions stayed open |
| DUPLICATE-OF | 1 | open population; CX-d81c duplicates CX-tq3f |
| CLEAR-CLAIM | 28 | in-progress population; all 28 exported with `claimed_by=nil` |
| **total** | **43** | **15 + 28** |

## Description-less tickets

The ruling says there are three. The supplied, asserted-byte-identical export
contains only **two explicit description-less markers**, for **CX-d81c** and
**CX-tq3f** (`tix-reconcile-targets.md:923-935`). A corpus-positive control
finds 43 `TITLE:` lines, while exact search finds two `(no description: ...)`
lines (927 and 935); every other block has non-empty text after its title. A
third ID cannot be named from the supplied artifact without inventing one.
This ruling/export discrepancy is a finding and deviation, not silently
rounded to three.

## Near-misses

- **CX-b38c**: the subject says the L6 shape was ruled, but the artifact says
  the mechanism round is still owed before L2.
- **CX-fm7x**: the merge subject sounds like sync-scope closure, but the ticket
  and artifact distinguish an operator exclusion mechanism from the missing
  policy.
- **CX-d81c / CX-tq3f**: the registry-amendment subject and successful pin
  rerun could invite closure, but the opened evidence retains the bare
  `emission failed: :error` defect.
- **CX-5gkw**: the ticket ID appears in several later subjects; closure rests
  on the four changed victim tests plus the equal-denominator phase-a/b
  measurement, not those subjects.

## Findings, controls, and deviations

- Live findings from verification (reported, not fixed): CX-b38c's
  attenuated-code-authoring mechanism is still owed; CX-fm7x still lacks the
  general sync-scope policy; CX-tq3f still has the bare-error diagnostic
  surface. The phase-b artifact also records a live `Yelixer.DiffYjsTest`
  missing-module invalidation and the independently tracked HumanWebPlay
  greet-race (`295e3ead:...ci-red-classification.md:23-45`).
- Git-log measurement used a non-empty corpus of 1,670 commits. Positive
  control `CX-vvbh` matched; zero-match IDs were treated only as absence of a
  commit mention, never as proof that work did or did not happen. Dotted IDs
  were retained as distinct ticket IDs.
- Negative-result error shape was checked in Phase A: the sole local red said
  “0 failures” but returned rc=2 with 11 invalid tests, rather than being read
  as green (`b40fd252:...ci-red-enumeration-measurement.md:9-19`).
- No suite was run: the relevant effects were already preserved as committed
  equal-denominator measurements and targeted tests, so copying dependencies
  into `/tmp` would add no evidence to this transcription round.
- No production files, tickets, git metadata, or run logs were changed. No
  `mix format`, `mix precommit`, commit, pull, sync, or push was attempted.
- Intended commit message (for the reviewer, not executed):
  `docs: reconcile 43 tix statuses from artifact evidence`.

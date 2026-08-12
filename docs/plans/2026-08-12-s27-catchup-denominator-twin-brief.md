# S27 build brief: catch_up's denominator twin — CX-vddv (CX-5983 seam (b) on the BEAM-cluster path)

> **The work's ticket is CX-vddv** (filed through the gated verb, live-store
> verified 2026-08-12). Any doc line citing a ticket cites CX-vddv (or
> CX-5983 for the inherited basis) — no other id. Plan ruled this item
> inherits the S26 ruling's basis wholesale (#11413 ④): possession-not-
> adoption denominators are settled law; do not re-argue them. What is
> NOT inherited is the BEAM boundary — see the measurement task below.
> Basis re-derived at main @aed660e9 (post-S26): all file:line cites
> below were verified against that tree, not inherited from the audit.

## The measured defect (context, not a task)

`NodeSync.catch_up/3` (node_sync.ex ~:77) diffs adopted chains on BOTH
sides: `CommitStoreClient.commit_ids_for_doc(local_store, doc_uuid)`
locally and `GenServer.call({CommitStore, remote_node},
{:commit_ids_for_doc, doc_uuid})` remotely. Possessed-but-unadopted
commits (genuine siblings; historic pre-S26 unadopted children) are
invisible on both sides, so: a local unadopted commit is re-fetched
every catch_up (import returns `:already_exists`, discarded by the
`Enum.each`); sibling-held history is never SENT onward (a third node
syncing through this one does not receive it — the partition-healing
gap); symmetric for the remote's unadopted commits. No crash — results
are discarded — which is also the second defect: the return
`%{fetched: n, sent: n}` counts TRANSFER attempts and discards every
import outcome. All imports could fail and the report reads success —
the same measure-downstream shape as CX-5983's `imported=1`.

## The ruled seams

1. **Local denominator** → `CommitStoreClient.all_commit_ids_for_doc/2`
   — the wrapper S26 added for exactly this population.
2. **Remote denominator** → the remote call asks for possession too:
   `{:all_commit_ids_for_doc, doc_uuid}`. The `handle_call` exists at
   commit_store.ex:1950 and PREDATES S26 — verify it at your worktree's
   sha and cite file:line in the report (cite-a-mechanism rule; do not
   inherit this cite).
3. **Report reflects landings, not attempts**: catch_up's return
   distinguishes, per direction, landed / already-present / deferred
   (`:awaiting_capability`) / rejected. The sent-side outcomes are the
   remote `import_commit` return values the current code already
   receives and discards; the fetched-side outcomes are
   `import_with_translation`'s returns. Shape of the map is yours;
   the meaning is fixed: a catch_up where nothing landed must be
   distinguishable from one where everything did.

## ⭐ THE MEASUREMENT TASK (the not-inherited part — answer, don't assume)

`catch_up/3`'s remote arm has NO test: two_node_sync_test.exs simulates
the transfer manually ("simulating catch_up without remote nodes"), so
the three `GenServer.call({CommitStore, remote_node}, ...)` sites have
never been exercised by the suite. The round must make the remote arm
testable. PROPOSED (additive only): an opts-injected remote-call
function defaulting to the current `GenServer.call` behavior, letting
tests drive both arms same-VM against two named stores. Before building
it, MEASURE: confirm no existing test reaches the remote arm (grep is
not enough — check the durable test files), and confirm the injection
point covers all three remote calls.

## ⛔ Escape hatches, up front

- If making the remote arm testable requires MORE than an additive opts
  parameter (a signature break, distributed test nodes, new infra) —
  STOP and report the options; that is a design call, not yours.
- Adoption behavior is NOT this round's: `import_with_translation`
  already adopts dominating imports (S26); sibling no-adoption is
  pinned there. If any catch_up change would alter WHAT gets adopted —
  stop; only WHAT IS DIFFED AND REPORTED changes here.
- No new write ingress: local imports stay on `import_with_translation`,
  remote sends stay on `import_commit`.
- Telemetry: this round touches NO telemetry events.
  `[:commonplace, :sync, :merge_adopted]` is out of scope; if you find
  yourself adding observability beyond the return map, stop and name it
  in the report instead. (A kind/pattern grep cannot see event
  subscribers — events in scope must be named, and here that set is
  empty.)

## Tests (red-first; suites named with on-main counts)

On-main baseline: two_node_sync_test.exs + node_sync_import_hook_test.exs
= 19/0 (measured @aed660e9); full core 3,397/0 + 1 skipped (the S26
landing gate; its 1 load-flake was WebPlayIntegrationTest, isolated-green,
outside this footprint too if it recurs).

1. **Possessed-sibling not re-fetched**: local store holds an imported
   unadopted sibling; remote offers it in its CID set → it must NOT
   appear in missing_local. Fails today by construction.
2. **Possessed-sibling IS propagated**: the same sibling absent from the
   remote's set → it MUST appear in missing_remote and be sent. Fails
   today (sibling not in local_ids at all).
3. **Positive control** (mirror S26's): a genuinely-missing CID is still
   fetched, and a genuinely-remote-missing commit still sent, while the
   possessed sibling is excluded from re-fetch.
4. **Report red-first**: a catch_up whose fetched commit is
   already-present (or whose send is rejected) must show that in the
   returned outcome counts — the old `%{fetched: n, sent: n}` shape
   cannot express it, so the assertion fails against current code.
- Existing 19 stay green; full core in-round with counts.
- Prove any "pre-existing/unrelated" failure with an isolated rerun —
  which licenses "outside this diff's footprint", not "flaky due to load".

## Review criteria

Both denominators possession-based with the remote handler cite verified
at the worktree sha; report distinguishes landings from attempts in a
shape a test asserts; the injection seam additive with the default arm
byte-equivalent to current behavior; sibling no-adoption untouched;
red-first transcripts included; measurement task answered with evidence,
not assumption.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). bd is a
frozen archive and answers "no issue found" for everything since
2026-08-05. A round that cannot file via the verb reports the identities
for the operator, stated as a deviation.

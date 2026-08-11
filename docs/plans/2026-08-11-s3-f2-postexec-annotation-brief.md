# S3 build brief: F2 post-exec correlation annotation — every punctuation event gains a witnessed outcome

> Plan's ruling ④ (msg 11155), from its schema review (F2, ruled msg 11091):
> a SIGNED, SEPARATE event carrying the resulting git sha, exit status, and
> final message — converting each punctuation event from declared intent
> into witnessed outcome. Step-1b-shaped. Buffer position: after S2.
> F3–F5's contract edits ride this round IF it touches the schema doc
> anyway (they are doc edits: replay keeps recorded predecessor; two-ref
> cap lifted with an explicit unresolved list; full verb table) — include
> them only where the doc is already open under your hands; do not expand
> code scope for them.

## ⛔ Escape hatch, up front

Stop and REPORT if:
- Emitting the post-exec annotation seems to require the emitter to run
  AFTER real git within the same process — the shim's structure (emit
  first, then real git) would make that a shim redesign, not an event
  addition. Expected shape: a SECOND, cheap emitter invocation (or
  subcommand) after real git completes, from the shim; if that expectation
  is wrong in a way you can name, report it.
- The annotation event's cost approaches the main emission's (it must NOT
  re-run sync_flush — it correlates, it does not re-pin; if the event
  schema seems to force a pin on every event kind, report).

## The gap (F2, plan's schema review — ruled, not speculative)

Today's punctuation event records `git-sha` PRE-exec (the observation is
taken before real git runs), so the event is a DECLARED intent: the
resulting sha, whether git succeeded, and the final message are all absent.
Measured in the cell demo: event 1's git-sha annotation is `1f94ace` (the
parent), while the commit it punctuated is `10a8e50`.

## The property

1. After real git completes, the shim invokes a post-exec annotation step
   that appends a SIGNED, SEPARATE event to the same event log, carrying at
   minimum: the correlated main event's ref, the RESULTING `git rev-parse
   HEAD`, real git's exit status, and the final human message (for commit
   verbs). Same signing principal as the main event.
2. NO second sync/pin: the annotation is cheap (observe + append). It must
   not call sync_flush or cut a checkpoint.
3. Failure honesty: if the MAIN emission failed/WALed, the annotation
   either rides the WAL envelope (extend proto-chit-wal's record with the
   post-exec facts) or is skipped WITH the skip visible in the WAL entry —
   named choice, never silent. If the ANNOTATION emission itself fails, it
   WALs like any emission (the CX-z0sa confirmation contract applies to it
   identically — the shim's token check must handle two invocations).
4. Contract doc: the schema doc gains the annotation event's shape. F3–F5
   edits per the header rule.
5. Predecessor semantics: the annotation must NOT advance the branch's
   predecessor ref (it correlates to the main event; the chain of record
   stays main-event to main-event) — unless reading the schema doc shows a
   ruled contrary, in which case report before choosing.

## Tests (red-first)

- RED-FIRST: tapped commit on unmodified code → event log holds ONE event
  whose git-sha is the PRE-exec parent (record it). After: main event plus
  annotation event; annotation carries the resulting sha (== the new HEAD),
  exit 0, and the message; predecessor refs unchanged in meaning.
- Failed-emission arm: emission WALs → post-exec facts land per your named
  choice (3) and the WAL entry shows it.
- Shim-level: the existing fake-emitter harness gains the two-invocation
  shape; the CX-z0sa confirmation tests keep passing.
- Events verified by READING THE LOG BACK (RedLog), never by exit codes.

## Gates

- proto-chit tests (core + cli + shim) + full core suite; counts reported.
- `mix compile --warnings-as-errors` clean. Tmp stores only.

## Deliverable

Work left UNCOMMITTED for the operator to land. Report: red-first verbatim,
the choice made at (3) and (5) with the reasoning, test counts, deviations.

# CX-tj6b build brief: make Document.Diff cost O(changed span), not grapheme-Myers over whole files

## ⛔ Escape hatch, before anything else

Stop and REPORT (do not build around it) if any of these happen:
- The red-first bench does NOT reproduce (a 9KB append onto a 100KB base
  through `Commonplace.Document.Diff.diff/2` completing in under ~2s on
  unmodified code would contradict this brief's measurements — that is a
  finding, not a green light).
- The fix seems to require touching Yelixer internals (Item/Text/Encoding),
  the wire format, or `Watcher.do_apply_modify`'s CX-pyi structure (stable
  client_id + incremental ops). The defect is contained in
  `Commonplace.Document.Diff`; if it isn't, the diagnosis missed something.
- Any test would need real trust chains or node signing. This sandbox masks
  the node signing key — trust anchors resolve EMPTY in here, so chain
  verification structurally cannot work and any `:untrusted_root` you see is
  the fence, not a defect. Nothing in this brief needs signing beyond the
  fixture `signing_context` opts the existing sync tests already use.

## The defect (measured 2026-08-10/11, operating session)

`Commonplace.Document.Diff.diff/2` (apps/commonplace/lib/commonplace/document/diff.ex)
converts BOTH entire contents to grapheme lists and runs
`List.myers_difference/2` with no common-prefix/suffix reduction. Myers is
O((n+m)·d) in time and memory on lists; for file-scale inputs this is
catastrophic. Measured on this machine, append-shaped change (base +
distinct 9KB tail):

- base 10KB → 53,131ms and ~2.5GB transient memory
- base 20KB → 23,536ms
- base 40KB → 15,721ms
- base 80KB → 24,648ms (all with GBs of GC churn; variance is Myers'
  d-dependence + GC, the order of magnitude is the point)

Downstream consequence (context only — not this brief's scope):
`Watcher.do_apply_modify` feeds whole file contents through this on every
detected modification, so one modified ~500KB file made sync emission
balloon >10GB and OOM-killed a session (CX-tj6b's history). Secondary
quadratic factors in the same module: `patches_to_edits` accumulates with
`acc ++ [..]` and calls `length/1` on grapheme lists per patch.

## The property to build (not a prescribed mechanism)

1. `Diff.diff(old, new)` runs in time and memory proportional to the
   CHANGED REGION (plus a linear scan to find it), never to a
   grapheme-Myers over the full contents. Concretely: the red-first bench
   below must pass comfortably.
2. Semantics preserved exactly: for ANY old/new, applying the returned
   edits transforms old into new. This is the correctness anchor —
   assert it with `apply_diff` round-trips (`ContentType.get_content`
   after `apply_diff` == new), including:
   - append, prepend, middle replace, full replace, equal inputs (→ []),
     empty→content, content→empty
   - unicode at the boundaries: combining characters, emoji, CRLF — a
     prefix/suffix trim must never split a grapheme cluster (this is the
     one subtle hazard; test it explicitly with clusters straddling the
     trim boundary)
3. `patches_to_edits`' quadratic accumulators fixed in the same pass.
4. Edit GRANULARITY may become coarser for large changed regions (e.g., one
   delete+insert covering the changed span instead of fine-grained Myers
   output). That is acceptable — this diff feeds filesystem sync
   convergence, not collaborative character merging — but SAY SO in the
   commit message if you take that route. Reasonable shapes to weigh, not
   binding: common prefix/suffix trim (grapheme-safe) then Myers only on
   the small middle; a size cap above which the middle becomes a single
   replace; line-level pre-chunking. Pick by measurement, and keep
   fine-grained Myers for small middles so ordinary small edits keep their
   current granularity.

## Callers to check

`grep -rn "Document.Diff" apps/` — enumerate every caller, confirm each
only depends on the semantics in property 2 (content equality after
apply), and run their test files. Known caller: `Watcher.do_apply_modify`
(sync). If others exist (e.g. meta-doc writers), their tests are in scope
for the gate.

## Tests

- RED-FIRST (record the failing/hanging output on unmodified code before
  the fix): `Diff.diff(100KB base, base <> 9KB tail)` inside a budgeted
  assertion. ⚠️ Wall-clock budgets are the suite's #1 flake class
  (CX-5gkw): size the budget per the sized-budget conventions you built —
  generous multiple of expected (expected after fix: low ms; budget can be
  seconds), and it must be RED on current code (currently ~25-50s, so a 5s
  budget is both safely red now and safely green after).
- Structural, timing-free: append yields exactly one `{:insert, len(old), tail}`;
  prepend yields one insert at 0; middle replace yields edits confined to
  the changed span (assert no edit touches the common prefix/suffix
  regions).
- The property-2 round-trip suite including the unicode boundary cases.
- Keep/extend the module's existing tests — find them with
  `grep -rn "Document.Diff" apps/commonplace/test/`.

## Gates

- `mix deps.get` if the worktree needs it (deps may be symlinked already).
- Targeted: the Diff test file + the watcher/sync test files.
- Blast radius: FULL core suite `mix test apps/commonplace/test` from THIS
  worktree root — Diff and sync are shared seams. Report exact counts; a
  pre-existing failure must be shown pre-existing (green in isolation or
  present on unmodified main), not absorbed.
- `mix compile --warnings-as-errors` clean.
- ⛔ Never run bare `mix test` (all apps); never open any store outside
  this worktree; tests use tmp dirs like the existing sync tests.

## Deliverable

One commit on branch `fix/cx-tj6b-apply-diff` (you are already on it), not
pushed. Commit message: the property, the measured before/after numbers
from the red-first bench, and the granularity note if coarsened. Then a
final report: red-first evidence verbatim, before/after timings, caller
enumeration, test counts (targeted + core), any deviation from this brief.

# S13-disc brief: who writes unsigned at boot? — MEASUREMENT ONLY (CX-vghh)

> Plan ranked CX-vghh first in the refill (msg 11253) and
> discriminator-before-brief applies: the mechanism is known only from a
> boot log. OBSERVED at the 3f1dd52 deploy (serve pid 3515796, Mode-B
> enforce): three `CommitStore: local write DENIED by trust gate
> (enforce)` warnings during startup — the WORKSPACE ROOT once, and a
> doc 967027b6-… twice which matches NOTHING in the schema (no root
> entry, nothing under chat/ or bd/; `__system` unmounted,
> scheduler_on_boot=false). Under enforce the writes are refused, so
> whatever mints them retries every boot and its work never lands.
> ⛔ Zero fixes this round. The deliverable is the WRITER TABLE and the
> identified culprits; the fix brief's shape depends entirely on them.

## ⛔ Escape hatch, up front

Stop and REPORT if the local reproduction (part B) produces ZERO
denials — that would mean the live denials depend on state your fixture
lacks (the real workspace's docs, a knob, a child disabled in test), and
the missing ingredient is the finding. Name what you varied.

## Part A — the boot-writer enumeration (code reading, with receipts)

Enumerate EVERY code path reachable during `Commonplace.Application.start/2`
(children + the ensure_*/bootstrap calls) that can reach
`CommitStore.create_commit` / `create_chained_commit` / `Issue.update` /
schema mutation. For each: module+function file:line, WHAT doc it writes
(root? fresh-minted uuid? named substrate entry?), and its SIGNING
posture (does it thread a `signing_context`? node identity or nothing?).
Known candidates to seed (find the rest): chat TemplateBootstrap,
Bd.Workspace.ensure_bd_dir, Bursar boot, reflog children, GhostReaper,
Scheduler.Agent mount, workspace-lock, GitBridge, presence. The table is
a deliverable regardless of part B's outcome.

## Part B — reproduce and attribute locally

1. Fixture: tmp store + workspace shaped like the live one (root schema
   WITH chat and bd entries present, no workspace_profile field — the
   legacy-absent population), `local_write_gate: :enforce` via app env,
   NO trust anchors (so unsigned writes deny exactly as live).
2. Boot the relevant startup sequence (the app's children or the boot
   functions the enumeration found — whichever the harness supports;
   say which you drove and why).
3. Capture EVERY denial with its doc_uuid AND its writer: instrument at
   the seam (trace `create_chained_commit`/`local_write_gate_check`
   callers, or capture Logger with metadata + a stacktrace hook — the
   mechanism is yours, but each denial must map to a code path, not a
   guess).
4. Match against the live signature: one root write + repeated writes to
   a fresh-minted uuid appearing in no schema. State whether your
   reproduction shows the SAME shape (count, targets) — and if the
   fresh-uuid writer mints a different uuid each boot, demonstrate that
   with two boots.

## Deliverable table

| writer (file:line) | doc written | signing posture | denied under enforce? | matches live denial? |

plus the attribution: which writer is the root write, which is
967027b6's class, and whether any OTHER unsigned boot writer exists that
the live log didn't show (because its doc already exists, its knob is
off, etc.) — the census must be complete, not just explain the three
observed lines.

## Gates

`mix compile --warnings-as-errors` clean if any instrumentation touches
code (prefer test-side instrumentation; production code untouched).
Tmp stores only. Full core suite NOT required for a measurement round —
run the test files your fixture lives in.

## Deliverable

Work left UNCOMMITTED (fixture/instrumentation test + the table doc in
docs/notes/). Report: the writer table, the attribution with receipts,
same-shape statement vs the live log, deviations. NO fix proposals —
the fix brief is authored on this measurement.

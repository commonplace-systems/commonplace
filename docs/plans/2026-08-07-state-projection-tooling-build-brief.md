> **THE DISPATCH ARTIFACT (settled 2026-08-07 00:52Z):** two briefs were drafted in parallel (the two-locks problem, caught by boss); plan's gate reviewed THIS one and passed it with two additions (both folded in below). commonplace-plan's parallel draft (`2026-08-07-state-projection-sol-brief.md` @8cbdbc6) stands as the design-conversation record. One brief, one gate, one dispatch.

# State-projection tooling — Sol build brief (jes directive 2026-08-07)

Designed jointly: commonplace-Fable + commonplace-plan + boss, #loom
2026-08-07 00:46–00:49Z. Plan gates this brief before dispatch.

## The problem (not the tool)

Post-compact, an agent reasoning correctly could not CHEAPLY answer "is this
already done?" — twice in five minutes the cheap path (re-derive scope from
briefs/source/memory-labels) beat the correct one (query the tracker), and
the tracker itself was stale-OPEN on three shipped tickets. Governing thesis:
**friction in reading state is a correctness property — the cheap path must
BE the true path.** Keystones from the design: *placement beats content* (the
only unconditionally-read artifact is what the harness loads); *the freshness
check lives with the READER's clock, not the writer's promise*; *a dead
renderer's last output must carry its own poison pill, by construction*.

## Components (all three; nothing here can open a store — reads in
## production go through the serve via the tix-migrate erpc harness, and
## Sol's own work uses FIXTURES only)

### 1. `bin/state-render` — the projection generator

The tix-migrate driver pattern (flock, inetrc, unique probe node,
`mix run --no-start`; read that script first). Connects to the serve,
reads ONLY long-deployed surfaces (`Bd.CLI.ready/blocked`, `Bd.Issue.list`,
`Issue.description`, comments via `Bd.Comment.list`), and writes THREE
artifacts atomically (temp + rename):

a. **`STATE.md` at repo root.** Sections, each with the L1 woven-expiry
   line as its FIRST line — not a footer:
   `> RENDERED 2026-08-07T00:40Z — TRUST UNTIL 01:40Z. Reading this later?`
   `> IT IS STALE: do not scope from it. Fallback: bin/state-render, or`
   `> tix via serve erpc, or git log --oneline --since=<week>.`
   Sections: FRONTIER (ready/blocked counts + top ~15 by priority, id +
   title + claimed_by); IN-FLIGHT (claimed/in_progress with holders);
   RECENT CLOSES (last 7 days: id, closed_at, title, **and a one-sentence
   WHAT-THE-FIX-WAS** pulled from the close-evidence comment's first
   sentence or `closed_reason` — bare ids reproduce the
   label-without-semantics failure and are forbidden; a close with neither
   source renders `(no close evidence recorded)` LOUDLY, never blank);
   OPEN-WITH-BLOCKER (open tickets whose latest comment names a blocker —
   the CX-x8jk state a status field can't express); TRACKER-TRUST (the
   scanner's last verdict line + when it ran, or `scanner has not run` —
   never absent).
b. **`.commonplace-state/tix-export.jsonl`** — machine-readable ticket dump
   (id, status, title, closed_at, updated_at), as_of-stamped in a header
   line. This is the scanner's offline input; it exists so truth-checking
   works with the serve DOWN.
c. **The CLAUDE.md pointer block** — between literal markers
   `<!-- state-projection:begin -->` / `<!-- state-projection:end -->`,
   regenerated wholesale every render (interception makes CLAUDE.md's
   accuracy load-bearing, and it was wrong twice on 2026-08-06 — the
   pointer must be generated output, never a hand claim). Content: two
   lines — read STATE.md before scoping any work; rendered-at timestamp.
   The generator must FAIL LOUDLY if the markers are absent (add them in
   this build, once, by hand, near the top of CLAUDE.md's project
   section) — it never writes outside them.

### 2. `bin/tix-truth-scan` — the both-directions scanner, OFFLINE

Inputs: `git log` (local) × the tix export from 1b (NOT the serve — must
run mid-outage). Joins CX-id references in merged commit subjects/bodies
against export status, both directions:
- **shipped-but-OPEN**: open tickets whose ids appear in merged commits —
  redundant-work hazard (last night's near-miss, twice).
- **closed-but-unreferenced**: closed tickets with code-shaped titles whose
  ids appear in NO commit — reported as SHAPES for review, not alarms
  (many closes are legitimately non-code; the output says so).
Per plan's rider: the scanner reports its INPUTS' AGES (git log is fresh by
nature; the export carries its as_of — denominator discipline applied to
the scanner's own sources), counts with denominators, per-hit shapes.
Writes its verdict line where `bin/state-render` picks it up for the
TRACKER-TRUST section (`.commonplace-state/scan-verdict.txt`). Exit 0 clean,
1 discrepancies found, 2 could-not-scan (never a silent empty).

### 3. `bin/state-prime` — the session-start injection (the reader's clock)

Reads STATE.md, parses RENDERED/TRUST-UNTIL from the woven lines, compares
against the LOCAL clock at invocation:
- fresh → emits the state block to stdout (this lands in session context);
- past trust-until → emits the LOUD STALE form: banner, age, DO NOT SCOPE
  FROM THIS, the fallback commands — and NOT the stale frontier content
  (past threshold the reader receives content that cannot mislead, not a
  rule they must obey);
- **missing or unparseable STATE.md → LOUD error to stdout** (boss's rider:
  a hook that silently emits nothing recreates the gap — no state block
  and no alarm must be impossible; silence is never a valid output).
Document exact invocation + exit codes in the script header for boss's
hook wiring (the harness half is boss's, not Sol's).

## Cadence and ownership (plan's required addition)

`bin/state-render` runs ONGOING via cron on this box every 30 minutes
(wired by boss alongside the session-start hook — host config is theirs;
the script must be safe under overlapping/failed runs: the flock in the
tix-migrate harness already serializes probes, and atomic rename means a
failed render leaves the previous STATE.md intact). **TRUST-UNTIL is
DERIVED from the cadence: rendered_at + 60m (2× the render interval)** —
so the stale banner means "the renderer is actually dead," never "we're
between renders"; a banner that cries between renders trains the reflex
this design exists to build. The interval and multiplier are constants at
the top of the script, changed together or not at all. Additionally,
procedural: any session that closes tickets re-renders before ending
(the same-day-close discipline's last step).

## Red-proofs (each control SEEN red before trusted, outputs in the report)

1. `state-prime` against a deliberately BACKDATED STATE.md → the stale
   alarm, verbatim capture. Against a DELETED STATE.md → the loud missing
   error. Against valid fresh → the state block.
2. Scanner against a fixture pair constructed with one planted
   shipped-but-open and one planted closed-but-unreferenced → both found,
   named; then the clean fixture → 0/0 with denominators shown.
3. Generator idempotency: two renders from identical fixture input →
   byte-identical STATE.md except the RENDERED stamps; CLAUDE.md outside
   the markers byte-untouched (assert!).
4. The close-without-evidence case renders its loud placeholder (never
   blank, never omitted).
5. Structural (plan's addition — the fencing header CLAIMS nothing can
   open a store; claims get checks): a grep-shape assertion over the three
   delivered scripts proving none references CubDB or opens a store
   directly — the class closed by construction, verified, not asserted.

## Fencing (unchanged, incident-day rules)

Sol: worktree only; NO serve contact, NO live store, NO distribution —
generator/scanner logic is built and tested against FIXTURES (fixture
export jsonl + fixture git repo made in tmp under the worktree). The
FIRST REAL RENDER against the live serve is the coordinator's act at
review, exactly like the comments backfill. Targeted test runs only,
one file per invocation, captured, `$?` checked; `--warnings-as-errors`
clean; commit small; do not push.

## Explicitly deferred (named so absence reads as decided, not missed)

- L3 serve-side projection-age alarm (audit-canary sibling) — follow-up
  ticket, rides a later deploy.
- HTTP CLI + auth model (serve signs server-side after bearer auth; CLI
  never holds the node key; serve-down writes stage per §4.5 WAL) —
  designed ticket superseding CX-a449's vehicle fork; plan gates.
- The procedural rider (brief EXECUTIONS mint-and-close a ticket at
  acceptance; DESIGN briefs stay ticketless) — one paragraph for
  CLAUDE.md's hand-written section + plan's discipline docs; not code.

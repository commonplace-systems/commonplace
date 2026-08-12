# S35 round-1 brief: the yelixer history disposition — CX-1mn4 (yelixer arc step 1)

> **The work's ticket is CX-1mn4** — the DISPOSITION ticket. Plan's queue
> row names S35 as "CX-fbah history disposition", but in tix those are two
> tickets and the dependency runs the other way: **CX-fbah *needs*
> CX-1mn4**. CX-fbah is the SYNC (branches and merges, a push); CX-1mn4 is
> the DISPOSITION (a decision doc, no push). This round is CX-1mn4 only.
> Its former blocker CX-3mj2 is CLOSED, so it is unblocked. Downstream and
> NOT this round: CX-fbah → CX-b6mz (dep flip) → CX-71m2 (delete
> apps/yelixer) → CX-bx59 (standalone CI).
>
> ⛔ **NO FORCE-PUSH — jes's standing ruling, and it is the reason this
> round exists.** ⛔ **THIS ROUND PUSHES NOTHING AT ALL.** Not to
> `commonplace-systems/yelixer`, not to any branch, not a tag. The output
> is a decision document plus a mechanism plan. A round that pushes has
> failed even if the push was correct.

## The measured ground truth (verify it; do not inherit it)

I measured the following before writing this brief. **Re-derive every line
— a disposition built on an unverified premise is the defect this repo
has spent a week naming.** The local clone is `/home/jes/yelixer`
(remote: `commonplace-systems/yelixer`, branch `main`); the umbrella is
this repo.

1. **The two histories share ZERO commit objects.** The standalone's tip
   `f87d43e` is not an object in the umbrella, and the umbrella's
   `cbbaddb1` is not an object in the standalone.
2. **Because the umbrella absorbed yelixer by SQUASH.** `523291ab` is
   `Merge commit 'cbbaddb1' as 'apps/yelixer'`, and `cbbaddb1` is a
   ONE-COMMIT history: *"Squashed 'apps/yelixer/' content from commit
   dd5988a"*. The squash deliberately discards the ancestry link — this
   is why no fast-forward exists in either direction, and it is a
   property of how the import was done, not of anyone's later mistake.
3. **`dd5988a` is a real commit in the standalone** — the split point.
4. ⭐ **THE FINDING THAT CHANGES THE ROUND'S SHAPE: the standalone has
   SIX commits AFTER the split point** (`19a7fe1`… then `dd5988a`, then
   `b2a79c6`, `1538962`, `b08f767`, `7e316f4`, `9d5775b`, `f87d43e` —
   confirm the exact set and order yourself). Their subjects name real
   CRDT fixes: zigzag encoding, boolean tag reversal + lib0
   `writeVarInt`, nested sub-type resolution in `YMap.to_json`, Yjs v14
   `xml_fragment` sub-types. **The stale-repo framing everyone has
   carried — "the standalone is 4.5 months behind, push our work to it" —
   is INCOMPLETE IN THE DIRECTION THAT LOSES DATA.** It is behind on 93
   umbrella commits AND ahead on 6 of its own.
5. Umbrella side: 94 commits touch `apps/yelixer`;
   `apps/yelixer/lib/yelixer/encoding.ex` is 1,970 lines against the
   standalone's 1,012.

## What this round produces

A decision document (`docs/plans/` in THIS repo, named for the date and
CX-1mn4) answering three questions in order. Nothing else.

### Q1 — the content audit of the six (this is the round's real work)

For EACH of the six post-split standalone commits, establish whether its
change is **present**, **absent**, or **superseded** in the umbrella's
`apps/yelixer` today, and say HOW you established it. This is a
behavioural question, not a textual one: the umbrella's encoding.ex is
nearly twice the size and has been independently rewritten, so a diff
that does not apply proves nothing either way.

- Prefer a test-shaped answer: does the umbrella exhibit the bug the
  commit fixed? Write a throwaway probe (do NOT commit new tests this
  round) or point at an existing test that covers it.
- ⛔ **"The diff doesn't apply" and "grep found nothing" are NOT verdicts.**
  Both are instrument failures wearing a verdict's clothes. If you
  cannot determine a commit's status, the honest cell is
  **INDETERMINATE with the reason** — an indeterminate row is a finding,
  a guessed row is a corruption.
- Any commit found **absent** is a real regression risk in a
  yet-unrecovered state: file it through the gated `ticket_create` verb
  as its own ticket, one per absent change, with the standalone SHA
  named. Do not fix them here.

### Q2 — the mechanism, ruled by the audit

Fast-forward is IMPOSSIBLE (finding 2, which you will have re-derived).
So the disposition is a choice among mechanisms, and the audit decides
which is honest. Evaluate at least: **(a)** `git subtree split` from the
umbrella producing a synthetic branch, merged into standalone `main`
with `--allow-unrelated-histories`; **(b)** a graft/replace object
linking `cbbaddb1` back to `dd5988a` so ancestry reads correctly;
**(c)** a merge commit with two unrelated parents and no rewriting.
For each: does it preserve the six commits' work, does it preserve
standalone `main`'s existing history unrewritten (the no-force-push
constraint is about HISTORY, not just about the flag), and what does a
future reader of `git log` correctly conclude.

**State a recommendation with its losing alternatives named.** A
disposition that lists options without choosing has not disposed of
anything.

### Q3 — what CX-fbah then executes

The concrete next-round plan: branch names, the merge direction, the
order, and the verification (the standalone's suite must be green at the
result — CX-3mj2 landed `diff_yjs` in CI asserting a test COUNT, so say
the count you expect). This is a plan CX-fbah transcribes, not work you
do.

## ⛔ Escape hatches, up front

- **No pushes, no tags, no branch creation on any remote.** Local
  experiment branches in a scratch clone are fine and expected; state
  that they were local.
- **No rewriting of standalone `main`** even locally-then-proposed —
  the ruling is against rewriting that history, and a plan whose first
  step is a rewrite is refused regardless of the mechanics.
- **Do not fix any absent change this round.** File it, name it, move on.
- If the audit shows all six are present/superseded, say so plainly —
  that is a clean, welcome result and it simplifies Q2. Do not
  manufacture a risk to justify the round.
- If a mechanism requires jes's ruling (anything touching the
  no-force-push boundary, or a `replace` object that changes what
  clones see), STOP and name the question for the operator rather than
  choosing.
- Telemetry, production code, tests: NONE of these change this round.
  The diff should be one new markdown file.

## Tests

None — this round changes no code. The verification is the audit's own
method disclosure. If you write probes, say they were throwaway and were
not committed.

Baseline for the record, unchanged by this round: full core 3,444 / 0
failures / 1 skipped @e6c6bb8f.

## Review criteria

Every measured line above independently re-derived (say how); the
six-commit audit table complete with per-row method and INDETERMINATE
used where earned; absent changes filed as their own tickets with SHAs;
a recommended mechanism with named losing alternatives; the CX-fbah plan
concrete enough to transcribe; **zero pushes — the reviewer checks
`git -C /home/jes/yelixer log origin/main -1` is unchanged and that no
remote refs were created**; diff is exactly one markdown file.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). bd is a
frozen archive and answers "no issue found" for everything since
2026-08-05. A round that cannot file via the verb reports identities
for the operator, stated as a deviation.

# CX-fbah build brief: execute the yelixer sync — the push round

> **The work's ticket is CX-fbah.** Context labels, none the citation:
> CX-1mn4 was the disposition (landed @e72857a9,
> `docs/plans/2026-08-12-cx-1mn4-yelixer-history-disposition.md`) — its
> §"Exact downstream execution plan" is this round's spine and its audit
> is what licenses the round to exist. Downstream and NOT this round:
> CX-b6mz (dep flip), CX-71m2 (delete `apps/yelixer`), CX-bx59
> (standalone CI).
>
> ⛔⛔ **THIS ROUND PUSHES — AND THAT INVERTS EVERY FENCE THE LAST ONE HAD.**
> Every round today has been safe by not-doing. This one is safe only by
> doing exactly one thing and stopping. Read the escape hatches before
> the plan.

## Why this round runs NOW, and the reason matters

**Because the route is PERISHABLE, not because it just became licensed.**
Those are different justifications and only one survives review.

The mechanism the disposition chose — subtree split reconstructing a real
merge base at `dd5988a`, then an ordinary append-only merge — works
because the umbrella's local object store physically retains the 20
pre-split standalone commits. **Those objects are UNREFERENCED. Routine
`git gc` prunes them at any time.** The route does not become wrong when
they vanish; it becomes more expensive and more error-prone (see step 1).
That decay term is the whole reason this pre-empts S36, and S36 resumes
immediately after, unmoved.

⛔ **Do NOT write "now that CX-1mn4 licenses it" as the justification
anywhere.** Licensing explains why the round is *permitted*; prunability
explains why it is *now*.

## What this round does

Execute the disposition's eight-step plan. It is deliberately specific;
transcribe it, do not redesign it. The end state is: standalone
`commonplace-systems/yelixer` `main` advanced by **exactly one ordinary
merge commit**, first parent `f87d43e` (its current tip), second parent
the umbrella subtree split, tree byte-identical to the split tip.

### The precondition that is not housekeeping (step 1–2)

`git subtree split` reconstructs pre-squash ancestry **only if the split
point's objects are present**. Verify, do not assume:

- Assert `dd5988a` is present in the working clone BEFORE splitting.
- If absent, fetch it from `/home/jes/yelixer` (a local fetch suffices
  and need not create a remote ref). Then assert again.
- ⭐ **The failure is loud, not silent** — the disposition proved this in
  a `file://` clone: the split aborts because it cannot parse the
  recorded split hash. So a missing precondition CANNOT quietly produce
  an unrelated-history merge. **If you ever find yourself reaching for
  `--allow-unrelated-histories`, the precondition failed and the answer
  is to satisfy it, never to pass the flag.**

### The verification before the push (steps 3–6)

- The split's merge base with standalone `main` is **exactly `dd5988a`**.
  Not "a merge base exists" — that exact SHA. Stop otherwise.
- The split tip's tree equals `apps/yelixer` at the audited umbrella tip.
- After merging: both tips are ancestors; parent ORDER is correct
  (standalone `main` first); **all six standalone SHAs are ancestors**
  (list them explicitly — `b2a79c6`, `1538962`, `b08f767`, `7e316f4`,
  `9d5775b`, `f87d43e`); `git diff --exit-code <split-tip> <merge-tip>`
  succeeds.
- The disposition's scratch run reported 12 conflicts. **That is
  diagnostic, not an acceptance constant** — do not assert the number.
- Standalone suite green at the result, with `diff_yjs` against both
  oracles: **11 tests, 0 failures, 0 invalid, 0 skipped per oracle**. A
  missing oracle is NOT green (CX-3mj2's whole point: assert the COUNT,
  never an exit code).

### The push (steps 7–8)

- Recheck the remote baseline **immediately before** publishing: standalone
  `origin/main` must still be `f87d43e`. Any movement ⇒ STOP and hand back
  for re-audit; do not merge over it.
- One normal, non-force push of the validated merge to `main`.
  ⛔ **`--force`, `--force-with-lease`, and any history rewrite are
  forbidden — jes's standing ruling.** A natural non-fast-forward
  rejection is a STOP SIGNAL, never a prompt to escalate the flag.
- Create **no remote scratch branch and no tag.**
- Then verify the PUBLISHED state (step 8), not your intent.

## ⛔ Escape hatches, up front

- ⛔ **Exactly one remote ref may move: standalone `origin/main`, by
  exactly one merge commit.** Anything else — a second push, a tag, a
  branch, a rewrite, a push to the umbrella's yelixer path — is out of
  scope even if it looks helpful.
- Nothing in the umbrella repo changes. No dep flip (CX-b6mz), no
  deletion of `apps/yelixer` (CX-71m2). Those need the sync landed AND
  green first.
- If ANY verification in steps 3–6 fails, STOP with the state recorded
  and hand back. A partially-verified push is the one outcome worse than
  no push.
- If the SSH host-key verification that blocked the disposition's
  `ls-remote` also blocks the push, STOP and report — that is an operator
  action, not something to work around.
- Telemetry, production code, tests in this repo: NONE change.

## What lands in THIS repo

An evidence note under `docs/notes/` recording the executed run: the
commands, the verification outputs, the final published SHAs, and the
suite counts. That note is the round's artifact.

## Review criteria

⭐ **The reviewer checks the PUBLISHED STATE, not the report** — "we
pushed correctly" is exactly the claim that needs an artifact. Expect the
reviewer to independently derive, from the repositories:

- standalone `main` is one commit ahead of `f87d43e`, and that commit is
  a merge;
- its first parent is `f87d43e` and second is the split tip;
- all six standalone SHAs are ancestors of the new tip;
- its tree equals the split tree (`git diff --exit-code`);
- `dd5988a` is the merge base of the two parent lines;
- **no other ref moved** — remote ref set is still exactly `origin/main`,
  no tags;
- reflog/ancestry shows nothing was rewritten: `f87d43e` is still
  reachable and unchanged.
- The evidence note's counts match a rerun where cheap.

Plus: the justification in the note is PRUNABILITY, not licensing.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). bd is a
frozen archive and answers "no issue found" for everything since
2026-08-05. A round that cannot file via the verb reports identities for
the operator, stated as a deviation.

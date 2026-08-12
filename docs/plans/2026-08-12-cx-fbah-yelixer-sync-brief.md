# CX-fbah build brief: execute the yelixer sync — the push round

> **The work's ticket is CX-fbah.** Context labels, none the citation:
> CX-1mn4 was the disposition (landed @e72857a9,
> `docs/plans/2026-08-12-cx-1mn4-yelixer-history-disposition.md`) — its
> §"Exact downstream execution plan" is this round's spine and its audit
> is what licenses the round to exist. Downstream and NOT this round:
> CX-b6mz (dep flip), CX-71m2 (delete `apps/yelixer`), CX-bx59
> (standalone CI).
>
> ⛔⛔ **REVISED BEFORE DISPATCH — THIS ROUND DOES NOT PUSH.** The first
> draft of this brief told the builder to push. It could not have
> succeeded: the sandbox mounts a tmpfs over `~/.ssh`, so a sandboxed
> builder has no key and no `known_hosts` **by design** — that mask is
> exactly what makes it safe to hand an agent write access to a worktree
> without worrying where the work ends up. The S35 round's `ls-remote`
> failure was never a host problem to fix; it was **the fence reporting
> itself**, and it was misfiled as a deviation when it was a capability
> boundary.
>
> ⇒ **The round is now PREPARE-AND-VERIFY. The push is a separate act by
> a principal outside the sandbox, on an object that has already passed
> every criterion.** That is strictly better than the original: this
> brief's own standard was *"we pushed correctly is exactly the claim
> that needs an artifact"* — and now the artifact exists and is fully
> verified BEFORE the irreversible step instead of being reconstructed
> after it.
>
> ⛔ Every fence below still binds the builder. What changes is that the
> last one is now enforced structurally as well as stated — and a fence
> that holds by construction is not a reason to stop stating it.

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

Execute steps 1–6 of the disposition's eight-step plan — everything up
to but NOT including the push. Steps 7–8 belong to the operator and are
described here only so the handoff is complete. The plan is deliberately
specific; transcribe it, do not redesign it.

**The round's product is a MERGE COMMIT that exists locally and has
passed every verification, packaged so it can be pushed without being
rebuilt.** Its shape: first parent `f87d43e` (standalone's current tip),
second parent the umbrella subtree split, tree byte-identical to the
split tip.

### ⭐ The handoff artifact — a bundle, because the object must survive

The worktree is destroyed at landing, so "the merge is in my scratch
clone" would lose it, and re-running the recipe elsewhere would produce
a DIFFERENT commit (committer and timestamp are inputs to the SHA).
Rebuilding is not the same as handing over.

- Write **`cx-fbah-yelixer-sync.bundle`** into the worktree root, via
  `git bundle create`, containing the merge commit and everything needed
  to place it on top of `f87d43e`.
- **State the merge commit's full SHA in the evidence note.** That SHA is
  the contract: the reviewer verifies THAT object, and the operator
  pushes THAT object. Any step that changes it invalidates the
  verification and the round restarts.
- Verify the bundle before declaring done: `git bundle verify` it, and
  confirm that a fresh clone of the standalone plus a fetch from the
  bundle yields exactly the stated SHA.

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

### The push (steps 7–8) — NOT THIS ROUND, stated for the handoff

The builder performs none of this and must not attempt it. Recorded so
the operator inherits a complete instruction:

- Recheck the remote baseline **immediately before** publishing: standalone
  `origin/main` must still be `f87d43e`. Any movement ⇒ STOP and re-audit;
  do not merge over it.
- Push the bundle's exact merge commit — the SHA stated in the evidence
  note — as one normal, non-force push to `main`.
  ⛔ **`--force`, `--force-with-lease`, and any history rewrite are
  forbidden — jes's standing ruling.** A natural non-fast-forward
  rejection is a STOP SIGNAL, never a prompt to escalate the flag.
- Create **no remote scratch branch and no tag.**
- Then verify the PUBLISHED state, not the intent.

## ⛔ Escape hatches, up front

- ⛔ **NO REMOTE MUTATION OF ANY KIND, and no attempt at one.** No push,
  no tag, no remote branch. The sandbox also enforces this (tmpfs over
  `~/.ssh`), and that is deliberate redundancy, not permission to test
  the boundary. ⚠️ **A network-auth failure is this fence reporting
  itself — it is NOT a defect to route around, and it must be reported
  as the boundary rather than filed as a deviation.** (That misfiling is
  precisely what cost this round its first shape.)
- When the operator later pushes, exactly one remote ref may move:
  standalone `origin/main`, by exactly one merge commit.
- Nothing in the umbrella repo changes. No dep flip (CX-b6mz), no
  deletion of `apps/yelixer` (CX-71m2). Those need the sync landed AND
  green first.
- If ANY verification in steps 3–6 fails, STOP with the state recorded
  and hand back. **Handing over a partially-verified object is the one
  outcome worse than handing over nothing** — the operator's push
  inherits your verification and cannot re-derive it.
- Telemetry, production code, tests in this repo: NONE change.

## What lands in THIS repo

An evidence note under `docs/notes/` recording the run: the commands,
the verification outputs, **the merge commit's full SHA**, the split
tip's SHA, the suite counts, and the bundle's path and verification.
The note plus the bundle are the round's artifact.

## Review criteria

⭐ **The reviewer verifies THE OBJECT, not the report** — and here the
object exists before anything irreversible happens, which is the point of
the reshape. Expect the reviewer to derive independently, by fetching the
bundle into a throwaway clone of the standalone:

- the bundle yields exactly the SHA the note states;
- that commit is a merge whose FIRST parent is `f87d43e` and second is
  the split tip;
- all six standalone SHAs (`b2a79c6`, `1538962`, `b08f767`, `7e316f4`,
  `9d5775b`, `f87d43e`) are ancestors;
- its tree equals the split tree (`git diff --exit-code`);
- `dd5988a` is the merge base of the two parent lines;
- `f87d43e` is unchanged and still reachable — nothing was rewritten;
- placing it on `main` would be a FAST-FORWARD (i.e. `f87d43e` is an
  ancestor), which is what makes the eventual push non-force by
  construction rather than by flag discipline;
- **the live remote is untouched by this round**: standalone
  `origin/main` still `f87d43e`, ref set unchanged, no tags.
- The evidence note's counts match a rerun where cheap.

Plus: the justification in the note is PRUNABILITY, not licensing.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). bd is a
frozen archive and answers "no issue found" for everything since
2026-08-05. A round that cannot file via the verb reports identities for
the operator, stated as a deviation.

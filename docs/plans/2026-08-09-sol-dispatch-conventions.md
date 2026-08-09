# Sol dispatch conventions — the parts that are load-bearing

2026-08-09. Written after a night in which two separate pieces of uncommitted
Sol work were nearly or actually lost, and recovered only by a property nobody
had declared on purpose. **These are requirements, not tidiness.**

---

## 1. ⛔ THE RUN LOG LIVES BESIDE THE WORKTREE, NOT INSIDE IT

```
/home/jes/sol-<slug>/
├── sol-run.log      ← here
└── wt/              ← the worktree
```

**Why it is a requirement:** during CX-qh55's review a `git checkout --`, folded
into a cleanup command, reverted Sol's entire test file. Sol leaves everything
**unstaged by design**, so there was no commit to fall back on. The work was
recovered **byte-identically from `sol-run.log`, which records the applied
patch**.

⇒ **A log inside the tree it describes shares that tree's fate** — including
`git worktree remove`, and including whatever destroyed the thing you now need
the log to reconstruct. **It must outlive its subject.**

⚠️ Also: **name the worktree path in the dispatch message.** Inferring it from
the ticket id cost a wrong lookup at `sol-<ticket>/sol-run.log` on a run that
lived at `sol-<ticket>2/`, and *"no such file"* reads as *"the run produced
nothing"* — the not-there/blocked collision.

## 2. ⛔ SNAPSHOT THE RETURNED RUN BEFORE REVIEW TOUCHES IT

**First act on a returned run, before reading the diff, before probing:**

```
bin/cp-sol-snapshot /home/jes/sol-<slug>/wt
```

**Why:** the fence's *leave everything unstaged* rule is correct — it is what
stops Sol writing git metadata — but its consequence is that **Sol's output
exists in exactly one place for the entire duration of review.** And review is
precisely when you probe, perturb and revert. ⭐ **`git checkout --` is `rm` for
uncommitted work**, and it is easy to use as though it were undo.

The snapshot parks the whole worktree state (tracked **and** untracked) at
`refs/sol-snapshot/<branch>`:

- **not on the branch**, so it can never be merged by accident
- **index untouched**, so the normal narrow `git add <paths>` flow is unchanged
- recover with `git restore --source refs/sol-snapshot/<branch> -- <path>`

⚠️ **Snapshot broadly; COMMIT NARROWLY.** The snapshot deliberately sweeps
untracked files — that is the point. A `git add -A` at *commit* time does the
same thing with the opposite consequence: on 2026-08-08 it swept three
generated oracle `.bin` files into a branch as if they were fixtures, caught
only because `git merge` refused to overwrite them.

## 3. ⛔ ASK THE FILE, NOT THE GRAPH

`git merge-base --is-ancestor sol/<branch> origin/main` returns **true for every
Sol branch, always, including unmerged ones** — because Sol never commits, so
the branch tip never leaves the base it was cut from.

⇒ **It answers "did the branch move?", not "did the work land?"**, and for Sol
those are permanently different questions. Check the artifact:

```
git show origin/main:<path> | grep -c '<the thing that should be there>'
```

*(Adopting §2 changes this: once the reviewer snapshots and then commits, the
branch does move — but the snapshot ref itself is never an ancestor, so keep
asking the file.)*

## 4. Committing and merging are two commands

Commit **in** the worktree; merge **from** main via `bin/cp-merge`, which
refuses to run anywhere else. A leading `cd <worktree>` persists through a
compound command, so `cd wt && git commit && git merge` merges the branch into
itself — *"Already up to date"*, then the push fails on an upstream mismatch.
Three times in one night, each time noticed and repeated.

⇒ Same family as **a count from a piped listing is not a count** and **the rc
you act on never comes through a pipe**: *a pipe or a leading `cd` silently
redefines the context of the next thing.*

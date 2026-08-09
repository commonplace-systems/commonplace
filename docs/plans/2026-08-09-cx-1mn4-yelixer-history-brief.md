# BUILD BRIEF — CX-1mn4: history disposition for the standalone yelixer

**For:** Sol (codex)
**Ticket:** **CX-1mn4** (p1)
**Worktree:** `/home/jes/sol-1mn4/wt` · **branch:** `sol/cx-1mn4`
**Run log:** `/home/jes/sol-1mn4/sol-run.log` (beside the worktree, not inside)

⛔ **THE DELIVERABLE IS AN ANALYSIS AND A RECOMMENDATION. NOT A PUSH, NOT A
MERGE, NOT A REWRITE.** jes's standing ruling: **NO FORCE-PUSH.** Do not push
anything anywhere. Do not modify `/home/jes/yelixer`.

---

## 0. Environment contract (standing)

Named worktree off **current** `origin/main`; ⛔ git metadata read-only in the
worktree, **leave changes UNSTAGED**, no `git add`, no commit; ⚠️ rc from the
command itself, never a pipe; ⚠️ **a count from a piped listing is not a
count**; ⚠️ **the default is not the value** — read constants at the call site.

⛔ **RUNNING ANYTHING LONG:** each `exec` gets a **fresh PID namespace**, so a
process started by one command is invisible to `ps`/`pgrep` in the next.
**Redirect to a file and read the file. Never poll the process table.**

### ⚠️ WHAT THE FENCE MASKS — measured, so you can read your negatives

- ⛔ **No `~/.ssh`, no `~/.config/gh`.** The clone at `/home/jes/yelixer` has an
  **SSH** remote (`git@github.com:commonplace-systems/yelixer.git`) — **you
  cannot fetch through it.**
- ✅ **BUT THE REPO IS PUBLIC AND READABLE UNAUTHENTICATED OVER HTTPS.**
  Measured from outside the fence:
  `git ls-remote https://github.com/commonplace-systems/yelixer HEAD` → `f87d43e…`
  ⇒ **Use the HTTPS URL.** If an SSH fetch fails, that is the fence, not a
  finding.
- ⚠️ **Verify you actually reached it** before reporting anything about the
  remote: a network failure inside the fence looks exactly like an empty
  history. **State which URL you used and what it returned.**

## 1. Measured baseline — established before this brief, re-derive anything you use

| | standalone (`/home/jes/yelixer`) | umbrella (`apps/yelixer`) |
|---|---|---|
| HEAD | `f87d43e` | `35cb391` |
| commits | **26** | **85** touching `apps/yelixer` |
| last commit | **2026-03-24** | **2026-08-09** |
| `encoding.ex` | **1,012 lines** | **1,970 lines** |

⛔ **Shared commit SHAs between the two histories: ZERO.**

⚠️ **AND THAT ZERO IS NOT THE ANSWER YOU MIGHT THINK.** The umbrella's commits
are **whole-repo** commits touching many paths; a subtree that was split out
would have **different SHAs by construction**. ⇒ **"0 shared SHAs" proves
fast-forward is impossible and says NOTHING about content lineage.** Do not
report it as evidence of unrelated content.

## 2. The actual question

**Is the standalone's history a content-ancestor of the umbrella's
`apps/yelixer`, or did the two diverge?**

Suggested approach — **you may choose another, but say which and why**:
1. `git subtree split --prefix=apps/yelixer` on a **throwaway ref** in your
   worktree, producing a synthetic subtree history.
2. Compare the standalone's 26 commits against it **by TREE CONTENT**, not by
   SHA. For each standalone commit, does its tree appear anywhere in the split
   history?
3. Characterise the divergence: **does the standalone contain any commit whose
   content is NOT reachable in the umbrella?** That single question decides
   everything downstream — if the answer is no, the standalone is strictly
   behind and the disposition is easy; if yes, there is unique work in the
   standalone that a naive replacement would destroy.

## 3. ⛔ Acceptance — artifacts, not assurances

1. ⭐ **A DIRECT ANSWER TO §2's ONE QUESTION**, with the command that produced
   it and its raw output pasted. *"Fast-forward is/is not possible because…"*
2. ⭐ **THE LIST OF STANDALONE COMMITS WHOSE CONTENT IS NOT IN THE UMBRELLA**,
   by SHA and subject — **or an explicit statement that the list is empty and
   the command that shows it empty.** ⛔ **An empty list asserted without the
   command that produced it is not a result.**
3. **A recommended disposition** (fast-forward / merge / graft / re-split) with
   **what each option costs** — specifically **what history each one loses.**
   ⛔ **Recommend; do not execute.**
4. ⚠️ **Name anything you could not verify**, especially anything where the
   fence could have produced the negative. **State the fetch URL and its
   result.**
5. ⛔ **No pushes. No writes to `/home/jes/yelixer`. No force-anything.** If
   your approach seems to require one, **stop and report that instead.**

## 4. Out of scope

- Actually reconverging the repos (that is **CX-fbah**, and it depends on this
  decision).
- Any change to `apps/yelixer` in the umbrella.
- Any other defect: **report it, don't fix it.**

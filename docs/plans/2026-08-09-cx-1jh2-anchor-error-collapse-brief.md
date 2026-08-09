# BUILD BRIEF — CX-1jh2: both anchor consumers collapse `:absent` and `{:error, _}` to `[]`

**For:** Sol (codex) · plan's **2=**
**Worktree:** `/home/jes/sol-1jh2/wt` · **branch:** `sol/cx-1jh2`
**Run log:** `/home/jes/sol-1jh2/sol-run.log`

---

## 0. Environment contract (standing)

Named worktree off **current** `origin/main`; ⛔ leave changes **UNSTAGED**, no
`git add`, no commit, no push; ⛔ **no serve, no live store** — the live store is
`/home/jes/commonplace/workspace/.commonplace/commits/`, **process-derived, NOT
repo-root and NOT `data/`**. ⚠️ **`mix deps.get` first.**

⚠️ **rc from the command itself, never through a pipe.** ⛔ **NO BARE ZEROS** —
any `0` arrives with a positive control that the pattern matches something.

## 1. The defect

`a4e708d` deliberately made `NodeIdentity.public_keys/0` return three
distinguishable outcomes, and its moduledoc explains why:

    {:ok, keys}   the artifact says these keys
    {:ok, []}     the artifact is present and declares ZERO keys
    :absent       there is no artifact

⇒ **Both consumers throw the distinction away, byte-identically:**

```
apps/commonplace/lib/commonplace/trust.ex:816        Trust.anchor_keys/1
apps/commonplace/lib/commonplace/mud/verbs.ex:582    MUD.Verbs.local_anchor_keys/0

    case NodeIdentity.public_keys() do
      {:ok, keys}  -> keys
      :absent      -> []
      {:error, _}  -> []      # <-- a READ FAILURE becomes "no keys"
    end
```

- `:absent` → **no artifact** → falling back to configured anchors is correct
  and intended. **Keep it.**
- ⛔ `{:error, :corrupt_node_public_keys}` → **the artifact EXISTS and could not
  be read.** Treating that as `[]` silently drops the node's own key from the
  anchor set and verification continues against a smaller trust set. **Nothing
  logs, nothing refuses, and the resulting `false` looks exactly like a policy
  decision.**

⭐ **The producer was built to make this visible; the consumers make it
invisible again two lines away — which is worse than never distinguishing it,
because the distinction now exists and reads as if it were being used.**

⚠️ **And a collapsed `false` poisons denial data**: a corruption-induced denial
is counted as a legitimate one.

## 2. ⭐ The hand-kept copy moved UP A LAYER — this is the fix's real shape

The **data** duplication was removed when both sites started calling
`public_keys/0`. ⇒ **The OUTCOME POLICY is now hand-kept in two byte-identical
copies.** `trust.ex:798` already carries a comment saying `local_anchor_keys/0`
is a hand-kept copy — **and it will NOT fail to compile if you change only one.**

⇒ **Put the collapse policy in ONE function** that both sites call, so
*no-anchors-by-policy* and *no-anchors-by-failure* are distinguished in a single
place and cannot drift apart again.

## 3. ⛔ Acceptance — artifacts

1. ⭐ **RED-FIRST: a corrupt artifact today**, showing the anchor set silently
   shrinking with **nothing emitted**. **Paste it**, and prove the precondition
   (the artifact exists and is unreadable) — otherwise the red proves nothing.
2. After the fix, a corrupt artifact is **loud**. The exact posture is your
   call — log-and-degrade, or refuse — **state which you chose and why.**
   ⛔ Do not silently swallow it; that is the defect.
3. **`:absent` keeps falling back to configured anchors, unchanged.** ⛔ Do not
   collapse the two in the other direction.
4. ⭐⭐ **THE PAIR TEST: a test that FAILS if only one of the two copies is
   fixed.** **This is the acceptance that pins the whole ticket** — the copy
   cannot fail to compile, so only a test can hold it.

## 4. ⛔ NAME THE SUITES BY BLAST RADIUS — not by the file you are editing

⚠️ **This rule exists because ignoring it cost two reverts on 2026-08-09.** A
change to how anchors are assembled is observed by **anything that verifies a
signature**, which is not confined to the app you are editing.

**Baseline each FIRST and report both numbers, one at a time:**

- `apps/commonplace/test/commonplace/trust` — **210 tests, 0 failures on main**
- `apps/commonplace/test/commonplace/mud` — **baseline it and report both**
- `apps/commonplace_web/test` — **12 features, 134 tests, 0 failures, 12 excluded**
- `apps/commonplace_mcp/test` — **156 tests, 0 failures**

⭐ *(All measured on main at `85f8990`. Older briefs quoting 195/196/197/201/206
for trust, or a non-zero web baseline, are stale.)*

- `mix compile --warnings-as-errors` rc=0.

⚠️ `CommitHoistTest` is load-marginal and genuinely unrelated (CX-qzbh: a 10s
budget inside a 9.9–13.9s workload). One line if seen; move on.

## 5. ⛔ Out of scope

- ⛔ Do not change `public_keys/0`, `public_key/0`, or the boot publish
  (`f6064e8`). **The producer is correct; this is a consumer defect.**
- ⛔ Do not touch `load_or_mint_keypair` — the mint refusal was reverted in
  `85f8990` and re-lands under **CX-8wh1** with a 43-fixture cleanup. **Do not
  re-add it, and do not build on its absence.**
- ⛔ CX-37d9 (fixed temp filename on the private-key write, `node_identity.ex`)
  is separate. **Read it so you do not reintroduce the pattern; leave it alone.**
- Any other defect: **one line, don't pursue it.**

## 6. What you cannot verify in-sandbox

- ⛔ Anything requiring the live serve — report **UNVERIFIED** and stop.
- ⭐ **You can build every case here from fixture directories**; a corrupt
  artifact is a file you write. **If you find yourself wanting the real node key,
  the scope has drifted — say so and stop.**

# BUILD BRIEF — CX-qvrz: publish the node's public-key artifact at boot

**For:** Sol (codex) · **blocks the deploy** (see §6)
**Worktree:** `/home/jes/sol-qvrz/wt` · **branch:** `sol/cx-qvrz`
**Run log:** `/home/jes/sol-qvrz/sol-run.log`

---

## 0. Environment contract (standing)

Named worktree off **current** `origin/main`; ⛔ leave changes **UNSTAGED**, no
`git add`, no commit, no push; ⛔ **no serve, no live store** — the live store is
`/home/jes/commonplace/workspace/.commonplace/commits/`, **process-derived, NOT
repo-root and NOT `data/`** (a stale decoy). ⚠️ **`mix deps.get` first.**

⚠️ **rc from the command itself, never through a pipe.** ⛔ **NO BARE ZEROS** —
any `0` arrives with a positive control that the pattern matches something.

## 1. The gap

Landed today (`a4e708d`): `NodeIdentity.public_key/0` reads the public half from
`node_signing_public_keys.json` and **never** from the private key. ⭐ **That is
correct and is the entire point — do not undo it.**

⚠️ But the artifact's **only** writer is `publish_public_keys/1`, called from
inside `signing_context/0` (`node_identity.ex:53`). **Nothing publishes it at
application boot.**

⇒ On a node that has not yet created a signing context, the artifact does not
exist, so `public_key/0` returns `{:error, :node_public_keys_absent}`.
`apps/commonplace/lib/commonplace/mud/sections.ex:211` calls it.

**Measured on the live workspace before deploying this:**

    workspace/.commonplace/node_signing_public_keys.json   ABSENT

⚠️ The window is probably small — a busy node writes constantly and the first
write publishes the artifact. ⭐ **But "probably small" is a claim about timing,
not about correctness, and the failing path is a MUD read with no reason to wait
for a write.** **The window is real, its size is unmeasured, and it is avoidable
entirely.**

## 2. What to build

**Publish the artifact at application boot wherever the identity already
exists**, so absence is not a state a running node can be in.

⚠️ **Boot ordering matters and you must state what you relied on:** whichever
supervision point you choose, say **why it runs before anything can call
`public_key/0`**, or say plainly that it does not fully close the window and how
much remains. ⛔ **Do not claim closure you have not demonstrated.**

## 3. ⛔ The trap — the obvious fix is the wrong one

⛔ **DO NOT make `public_key/0` fall back to reading the private key.**

⇒ That restores exactly the coupling `a4e708d` exists to remove, and — worse —
**the sandbox tests that now pass with the private key masked would keep
passing, for the wrong reason.** ⭐ **A green suite would then be evidence of the
defect rather than of the fix.**

⚠️ Equally: **do not make the fix depend on minting.** `load_or_mint_keypair`
now REFUSES when the key is absent and a prior world exists (`0053a8c`) —
publishing must work from an identity that already exists, and must not be a
back door into minting one.

## 4. ⛔ Acceptance — artifacts

1. ⭐ **RED-FIRST:** with the artifact deleted and **no signing context yet
   created**, show `public_key/0` failing on unmodified `main`. **Paste the
   actual return value.** ⛔ Prove the preconditions held (artifact absent) —
   otherwise the red proves nothing.
2. **After the fix, the same starting condition yields a published artifact and
   a successful read.**
3. ⭐⭐ **AND SHOW THE PRIVATE KEY WAS NOT READ TO ACHIEVE IT.** ⛔ *"It worked"*
   is satisfiable by the very coupling being removed. **Demonstrate under the
   fence's own condition — private key masked/unreadable — that the artifact is
   still published and read.** **This is the criterion that matters.**
4. **Key-absent + prior-world-present must still REFUSE** (`0053a8c`'s
   behaviour), unchanged. ⚠️ Your boot hook must not turn that refusal into a
   mint.
5. `mix compile --warnings-as-errors` rc=0, and — **baseline first, both
   numbers, one suite at a time:**
   - `apps/commonplace/test/commonplace/trust` — **210 tests, 0 failures on main**
   - `apps/commonplace/test/commonplace/crypto` — **37 tests, 0 failures on main**
     *(35 before `0053a8c`; older briefs saying 195/196/197/201/206 for trust are stale)*

⚠️ `CommitHoistTest` is load-marginal and genuinely unrelated (CX-qzbh). One
line if seen; move on.

## 5. ⛔ Out of scope

- ⛔ **CX-37d9** — the fixed-temp-filename race on the PRIVATE key write at
  `node_identity.ex:129`. **Filed separately and deliberately.** ⚠️ It is the
  same bug already fixed on the public path at `:146`, and it sits a few lines
  from your work. ⭐ **Read it so you do not reintroduce the pattern; leave it
  alone.**
- ⛔ Do not change `prior_world_evidence?/1` or the mint refusal.
- ⛔ Do not change `Trust.anchor_keys/1` or `MUD.Verbs.local_anchor_keys/0`.
- Any other defect: **one line, don't pursue it.**

## 6. Why this is ahead of the ranked queue

⚠️ **It blocks the deploy.** The live serve is **15 beams / 11 commits** behind a
start of 14:39, and tonight's deploy was held **because this defect would ship to
the live node**. ⭐ **Everything ranked below it is unverifiable in production
until the deploy moves**, which is precisely the "not-work-but-blocking"
argument. **commonplace-plan has been told and may re-rank.**

## 7. What you cannot verify in-sandbox

- ⛔ Anything requiring the live serve — report **UNVERIFIED** and stop. **I run
  the live check.**
- ⭐ **You CAN verify §4.3**, and it is the important one: the fence already
  masks the private key, so the condition you need is the condition you are in.

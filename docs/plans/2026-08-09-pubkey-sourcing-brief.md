# BUILD BRIEF — public-key sourcing: read the anchor's PUBLIC half from a public artifact

**For:** Sol (codex) · **Queue #2** (plan's ranking, unblocking-power)
**Worktree:** `/home/jes/sol-pubkey/wt` · **branch:** `sol/pubkey-sourcing`
**Run log:** `/home/jes/sol-pubkey/sol-run.log`

---

## 0. Environment contract (standing)

Named worktree off **current** `origin/main`; ⛔ leave changes **UNSTAGED**, no
`git add`, no commit, no push; ⛔ **no serve, no live store** — the live store is
`/home/jes/commonplace/workspace/.commonplace/commits/`, **process-derived, NOT
repo-root and NOT `data/`** (a stale decoy). ⚠️ **`mix deps.get` first.**

⚠️ **rc from the command itself, never through a pipe** — `mix test … | tail`
returns `tail`'s rc. ⛔ **NO BARE ZEROS**: any `0` comes with a positive control
that the pattern matches something.

⚠️ **Another agent is editing `apps/*/test/test_helper.exs` and
`test/support/` in a different worktree. DO NOT TOUCH THOSE FILES.**

## 1. The problem — one sentence

**Verifying a signature needs only the anchor's PUBLIC key, but the code obtains
it by reading the PRIVATE `node_signing_key` file** — which your sandbox masks
with `--ro-bind /dev/null` (deliberately, and that mask is load-bearing: without
it, a missing key would hit `load_or_mint_keypair`'s `:enoent` branch and **mint
a fresh node identity**).

⇒ **So every chain/capability test that needs a real anchor cannot run in the
fence.** Fixing this releases the sandboxed tickets queued behind it.

## 2. The two sites

1. `Commonplace.Trust.anchor_keys/1` — in `apps/commonplace/lib/commonplace/trust.ex`
2. `Commonplace.MUD.Verbs.local_anchor_keys/0` — ⚠️ **a hand-kept COPY of the
   same logic.** ⭐ **It will NOT fail to compile if you change only the first
   one.** Read both before changing either, and say in your report how they
   differ, if they do.

## 3. What to build

**A public artifact carrying the anchor's PUBLIC half**, and sourcing that
preferentially, falling back to today's behaviour when it is absent.

- The public key is derivable from the private key; the artifact is written at
  the point the identity already exists.
- ⛔ **Never read the private key to satisfy a public-key request.** That is the
  defect.
- ⚠️ **Absent artifact must NOT silently become "no anchors"** — a silent empty
  anchor set turns every verification into a `false` that looks like a policy
  decision. **Distinguish "no artifact" from "artifact says zero keys".**

## 4. ⛔ Acceptance — artifacts

1. ⭐ **THE CRITERION THAT MATTERS: a chain-verification test that needs a real
   anchor RUNS AND PASSES with the private key masked** — reproduce the fence
   condition with `--ro-bind /dev/null` over `node_signing_key`, or by pointing
   the config at a path that does not exist. **Paste it.**
2. ⭐ **RED-FIRST:** show that same test FAILING on unmodified `main` under the
   same masked condition, so the fix is demonstrated to be what changed it.
3. **Both sites updated**, or a stated reason why one should not be — and
   ⛔ **a test that would fail if only one were changed**, since the copy cannot
   fail to compile.
4. **Absent-artifact behaviour is distinguishable from zero-keys**, with a test.
5. `mix compile --warnings-as-errors` rc=0, and — **baseline first, both
   numbers, one at a time:**
   - `apps/commonplace/test/commonplace/trust` — **206 tests, 0 failures on main**
     *(measured 2026-08-09; older briefs say 195/196/197/201 — all stale)*
   - `apps/commonplace/test/commonplace/mud` — **baseline it and report both.**

⚠️ **`CommitHoistTest` fails ~50% under load and is UNRELATED (CX-qzbh: a 10s
budget inside a 9.9–13.9s workload). One line if you see it; move on.**

## 5. ⛔ Out of scope

- ⛔ **Do NOT touch `load_or_mint_keypair`'s mint-on-`:enoent`.** It is queue #3,
  a separate ticket, and a genuine trust-root hazard — **changing it here would
  entangle two independent fixes.**
- ⛔ Do not split the delegation root (queue #13), and do not change signing.
- ⛔ Do not touch `apps/*/test/test_helper.exs` or `test/support/` — another
  agent is in those files right now.
- Any other defect: **one line, don't pursue it.**

## 6. What you cannot verify in-sandbox

- ⛔ Anything requiring the live serve — report **UNVERIFIED** and stop.
- ⭐ **This ticket exists precisely so that a real anchor DOES work in the fence.
  If you find yourself unable to test without unmasking the private key, say so
  and stop — that outcome is itself the finding.**

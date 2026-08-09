# BUILD BRIEF — public-key sourcing, ROUND 2: fix the regression you called unrelated

**For:** Sol (codex) · **same worktree** `/home/jes/sol-pubkey/wt`, branch `sol/pubkey-sourcing`
**Run log:** `/home/jes/sol-pubkey/sol-run.log` (append)

---

## 0. What you got right — do not redo it

✅ Red-first was real and pasted. ✅ Both sites updated (`Trust.anchor_keys/1`
and the hand-kept `MUD.Verbs.local_anchor_keys/0`). ✅ `:absent` vs `{:ok, []}`
distinguished, with the reasoning in the moduledoc. ✅ **You did not touch
`load_or_mint_keypair`'s mint-on-`:enoent`** — the out-of-scope boundary held.

⭐ **Keep all of it. This brief is one regression, not a rewrite.**

## 1. ⛔ THE REGRESSION — and the claim that hid it

You reported:

> *MUD baseline: 694 tests, 3 failures; MUD after: 694 tests, 1 failure; sole
> failure was the **unrelated** concurrent-take race in `TakeTest`.*

⛔ **It is not unrelated. Measured, at matched machine load (~6.2–6.8):**

```
UNMODIFIED main         run1 rc=0   15 tests, 0 failures
                        run2 rc=0   15 tests, 0 failures
YOUR worktree           run1 rc=2   15 tests, 1 failure
                        run2 rc=2   15 tests, 1 failure
                        run3 rc=2   15 tests, 1 failure
```

⇒ **Green 2/2 on main, red 3/3 on your branch, same machine, same load.** ⚠️ *I
matched the load deliberately, because a concurrency test failing under load
proves nothing — that mistake was made on this repo this morning.*

## 2. ⭐ What actually broke — and what did NOT

`test/commonplace/mud/take_test.exs:256`, *"two concurrent takes of the same
item: exactly one wins, the other is refused"*:

```
code:  assert Enum.count(results, &(&1 in losing_reasons)) == 1
left:  0        right: 1        (at :280)
```

⭐⭐ **THE FAILURE IS AT :280, NOT :279 — SO `Enum.count(results, &(&1 == :ok)) == 1`
PASSED.** ⇒ **Exactly one take still wins. THE MUTUAL-EXCLUSION INVARIANT HOLDS.**
**This is an ERROR-SHAPE regression, not a safety break — do not "fix" it by
touching `Take`'s CAS logic.**

⇒ **The loser now fails with a reason outside**
`[{:error, :taken}, {:error, :item_unavailable}, {:error, :gone}]`.

## 3. The likely cause — CONFIRM IT, don't assume it

You changed `NodeIdentity.public_key/0` to read **only** the public artifact:

```elixir
{:ok, []} -> {:error, :no_node_public_keys}
:absent   -> {:error, :node_public_keys_absent}
```

⚠️ **It previously derived the public half from the keypair and effectively could
not be absent.** And `apps/commonplace/lib/commonplace/mud/sections.ex:211` calls
it in a path this test reaches.

⇒ **So a missing artifact now turns a CONTENTION refusal into a CRYPTO error** —
in production as well as in tests. ⭐ **That is worse than a failed assertion: a
"can't read my own public key" error is a security-shaped message for what is
actually two players grabbing the same item.**

⛔ **FIRST DELIVERABLE: report the loser's ACTUAL `{:error, reason}` value.** Print
it; do not infer it. **If it is not a public-key error, this whole section is
wrong and I want to know that.**

## 4. What to build

**Make `public_key/0` non-absent in practice, without ever reading the private
key to serve a public request.**

Options, your judgement — say which you chose and why:
- publish the artifact wherever an identity already exists, so absence is not a
  normal state; and/or
- have `public_key/0` fall back for callers that legitimately have a local
  identity, while `anchor_keys` verification keeps the artifact-only path.

⚠️ **Whatever you choose, `{:error, :node_public_keys_absent}` must not be
reachable from an ordinary MUD action on a healthy node.**

## 5. ⛔ Acceptance

1. ⭐ **The loser's actual error value, printed.** (§3)
2. **`test/commonplace/mud/take_test.exs` — 15 tests, 0 failures, rc=0, run
   THREE TIMES**, with `cat /proc/loadavg` beside each. ⛔ **One green run is not
   evidence for a concurrency test.**
3. ⭐ **Your §4 change must not weaken the red-first from round 1:** re-run the
   masked-private-key chain test and show it still passes. ⛔ **If your fix works
   by making the artifact optional in a way that lets the private key back in,
   that is a regression of the whole ticket.**
4. **Baselines, one at a time, rc from the command itself, never via a pipe:**
   - `apps/commonplace/test/commonplace/trust` — **206 on main, you reported 209 after; report both again**
   - `apps/commonplace/test/commonplace/mud` — ⚠️ **you reported a 3-failure BASELINE.
     Re-baseline it and NAME THE THREE.** ⭐ **A baseline with unexplained
     failures cannot support "no new failures", and 3 → 1 is a delta you never
     accounted for.**
5. `mix compile --warnings-as-errors` rc=0.

## 6. ⛔ Out of scope

- ⛔ **Do NOT change `Take`'s CAS or contention logic.** §2 proves the invariant
  holds; changing it would be fixing a symptom in the one place that is correct.
- ⛔ Do NOT touch `load_or_mint_keypair`'s mint-on-`:enoent` (still queue #3).
- ⛔ Do NOT touch `apps/*/test/test_helper.exs` or `test/support/` — landed on
  main since your run, and not yours.
- ⚠️ `CommitHoistTest` is load-marginal and genuinely unrelated (CX-qzbh). One
  line if seen.

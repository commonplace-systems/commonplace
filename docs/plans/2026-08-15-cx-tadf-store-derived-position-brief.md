# CX-tadf: the tombstone's chain position must be derived by the store

> **The work's ticket is `CX-tadf`.** Base: **the commit that adds this brief**
> — ⚠️ *not a sha.* **Build the worktree from that base.**

## What is true today — verified on `origin/main` before briefing

```elixir
# commit_store.ex — the position arrives in opts
chain_position = Keyword.get(opts, :chain_position)
known_tombstone_chain_position(state.db, chain_position)   # checks only that it EXISTS

# sla_tombstone.ex — an ACTIVE anchor skips the position check entirely
defp valid_at_chain_position(%EvictionAnchor{retired_at: nil}, _tombstone, _opts), do: :ok

# sla_tombstone.ex — verification prefers an opts-supplied position over the stored one
defp tombstone_chain_position(tombstone, opts) do
  case Keyword.fetch(opts, :chain_position) do
    {:ok, position} when not is_nil(position) -> {:ok, position}
    _missing -> CommitStoreClient.get_sla_tombstone_position(store, tombstone.id)
  end
end

# sla_tombstone.ex — the ORDERING RELATION itself is injectable
case Keyword.get(opts, :position_before?) do
  fun when is_function(fun, 2) -> fun.(position, anchor.retired_at)
  nil -> CommitStoreClient.is_ancestor?(store, position, anchor.retired_at)
end
```

⇒ ⭐⭐ **`CX-fmzk` established that a record must not supply its own verification
key. THE SAME PROPERTY IS NOT YET TRUE OF THE POSITION, OR OF THE RELATION THAT
ORDERS IT.**

## ⛔⛔ AND THE DOCSTRING ALREADY ASSERTS THE INVARIANT

```
:chain_position — THE STORE-SUPPLIED COMMIT ID at which the tombstone was recorded
:position_before? — injectable fixture seam. PRODUCTION uses the store's strict is_ancestor?/3
```
⇒ ⛔ **The doc says *store-supplied* while the code reads `opts`, and *"production"*
is doing load-bearing work that nothing enforces — production is simply whoever
does not pass the option.** ⭐ ***A docstring stating a property the code does not
enforce must become ENFORCED or become ACCURATE*** (`CX-vvbh`). **Here it must
become enforced: the accurate version — "store-supplied unless the caller
supplies something else" — describes no invariant at all.**
⚠️ *And it is why several reviewers, myself included, read this as closed.*

## ⛔ What to build

**A dedicated EVICTION-AUTHORITY LEDGER that the STORE appends to and assigns
positions from.** Activation, registration and retirement in **ONE ordering
domain**. ⇒ **The writer cannot nominate a position; the append and the index
rows land atomically.**

**Four properties, and all four are the ticket:**
1. ⭐⭐ **THE POSITION IS STORE-DERIVED AT BOTH ENDS** — at write, and at verify.
   ⛔ **Never from `opts`, on either path.**
2. ⭐⭐ **THE ACTIVE-ANCHOR SKIP IS REMOVED**, so **every tombstone carries a
   position from birth.** ⚠️ *Otherwise a tombstone written under an active
   anchor has no position, and becomes unreadable the moment that anchor
   retires — which is the rotation inversion this whole line of work exists to
   prevent, arriving through routine housekeeping rather than through anything
   adversarial.*
3. ⭐⭐ **NO CALLER-SUPPLIED ORDERING RELATION.** ⛔ **`:position_before?` must
   go, or become unreachable from the public verify path.** ***It is the same
   property as (1) with a function instead of a value, and closing (1) while
   leaving (3) open would be a half-fix.***
4. ⚠️ **`:revocation_fetcher` is the same shape on the same path.** ⭐ **Assess
   it; if it is the same defect, say so and fix it — if it genuinely differs,
   say why.** ⛔ **Do not silently leave it because it was not named.**

⚠️ **`is_ancestor?/3` walks ONE `parent_id` chain, so a retirement on one
document chain does not order tombstones on unrelated chains.** ⭐ **A single
ordering domain is what makes the comparison meaningful — if your design keeps
per-chain ancestry, state how cross-chain ordering is decided.**

## ⛔ Acceptance — artifacts, and the red arms come first

1. ⭐⭐ **RED FIRST, BOTH PATHS: show that TODAY a position and an ordering
   relation can BOTH be supplied through the public API, and that after the
   change NEITHER CAN.** ⛔ **Verbatim before-and-after values.**
2. ⭐⭐ **A tombstone written under an ACTIVE anchor HAS a position** —
   demonstrated by reading it back, **and it still verifies after that anchor is
   retired.** ⚠️ *This is the arm that proves the rotation inversion is closed on
   the DEFAULT path, not only the injected one.*
3. **A tombstone whose position is at-or-after the retirement point is REFUSED**,
   and the refusal names why.
4. **The quiet half: `CX-fmzk`'s arms all still pass** — anchored verifies,
   untrusted-signer refused, no-anchor refuses `:no_eviction_anchor_configured`.
   ⚠️ ***A change that makes everything fail passes the red arms and is worse
   than the defect.***
5. ⭐ **THE DOCSTRING MATCHES THE CODE WHEN YOU ARE DONE.** ⛔ *If any seam
   survives, the doc says so plainly rather than calling it "production uses…".*
6. ⭐ **PRINT EVERY ARM AND SHOW THE PAIRS DIFFER.**
7. **PER-FILE test counts, not only the suite total.** ⚠️ *Tonight a stable
   `3519 → 3519` concealed a deleted test offset by an added one.*

## ⚠️ THE SANDBOX CANNOT SIGN

**`node_signing_key` is MASKED** ⇒ `NodeIdentity.signing_context/0` fails and no
node-signed write succeeds. ⭐ **Use the injectable `opts[:signing_context]`
seam** — `sla_tombstone_test.exs` is the worked example. ⚠️ **Note the tension
and handle it deliberately: this round REMOVES injectable seams while DEPENDING
on one. `signing_context` is an input to the act; `position_before?` is the
evidence about the act. If that distinction does not hold up as you build, SAY
SO — it is the round's most interesting possible finding.**

## Suites

⛔ **`bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK.** **On-main:
`3519 / 0` at seed 117514, `origin/main` `928025b3`.** ⚠️ **BUILD FROM THAT BASE.**
⚠️ **The suite prints `GLOBAL STATE LEAK DETECTOR: <n> divergence(s) — ADVISORY,
not a failure` plus a line saying its positive control did not run. EXPECTED, not
a failure.** ⭐ **`<n>` has read 115, 118, 127 and 152 in different populations —
it is an UPPER BOUND, not a regression signal.** ⛔ **If it ever appears as a
FAILURE, that is a finding.**
⚠️ **Known reds by TEST and MECHANISM:** `CX-kx6d` — `GitBridge.ServerTest`
*"filters: __ / nosync / presence … across two cycles"*, teardown check-then-act
(`Process.whereis` then `GenServer.stop` → `no process`); **unticketed** —
`GitBridge.ServerTest` *"push: failure to an unreachable remote … retries"*,
`{:error, :already_registered}` from `WorkspaceFixture.complete_workspace!/2`;
`CX-s9kc` — `chat_view_compute_supervisor_test.exs`. ⛔ **ANY OTHER failure, or
either of those with a DIFFERENT error shape, IS YOURS — say which, verbatim.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`
  — workspace-relative, NOT repo-root, NOT `data/`.*
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.**
- ⭐ **Verify by RE-READ, not by the write returning.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES.**
  ⚠️ *Eight rounds running have produced their best result by correcting their
  brief — including three tonight that caught the author's own contradictions.*
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to close the position
  while leaving the relation injectable, or to leave `:revocation_fetcher`
  because this brief only mentioned it.
- ⭐⭐ **WHAT WAS THIS COPIED FROM, AND WHAT HAS BEEN COPIED FROM THIS?**

## Review criteria

Position store-derived at write AND verify with no `opts` path on either; the
active-anchor skip removed and every tombstone carrying a position from birth,
demonstrated by read-back and by surviving its anchor's retirement; no
caller-supplied ordering relation; `:revocation_fetcher` assessed and its
disposition stated; `CX-fmzk`'s arms still green; the docstring matching the code;
per-file counts reported.

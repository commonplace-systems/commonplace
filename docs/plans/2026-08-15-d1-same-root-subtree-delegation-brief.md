# D1: permit SAME-ROOT subtree delegation at mint

> **Design: `commonplace-plan:docs/plans/2026-08-15-subtree-delegation-depth.md`.
> This brief is self-contained — you do not need that repo.**
> Base: **the commit that adds this brief** — ⚠️ *not a sha.*

## What is true today — verified at source before briefing, twice, independently

```elixir
# capability.ex — the MINT guard that refuses
defp check_subtree_leaf_only(%{scope: {:subtree, _}}, _parent),
  do: {:error, :subtree_scope_not_delegable}

# verify_chain.ex — VERIFY already accepts a same-root subtree chain
Enum.all?(scopes, &match?({:subtree, _}, &1)) ->
  case scopes |> Enum.map(fn {:subtree, root} -> root end) |> Enum.uniq() do
    [single_root] -> {:ok, {:subtree, single_root}}
    _multiple     -> {:error, :subtree_scope_root_mismatch}
  end

# verify_chain.ex — delegation is gated by the :delegate VERB
defp delegation_allowed(%{claim: %{verbs: verbs}}) do
  if :delegate in verbs, do: :ok, else: {:error, :delegation_not_permitted}
end
```

⇒ ⭐ **A deployment cert carrying the CELL'S OWN ROOT, with a SUBSET of verbs and
a TIGHTER window, is expressible and verifiable TODAY.** ⛔ **Only the mint guard
refuses it — and its own comment says it is *"a fail-EARLY convenience, NOT the
load-bearing guard."***

## ⛔⛔ THE ONE DESIGN CONSTRAINT — get this wrong and mint becomes silently permissive

**ADD THE SAME-ROOT CHECK EXPLICITLY. DO NOT LEAN ON `attenuates?`.**

```elixir
defp scope_set({:subtree, _root}), do: MapSet.new([])   # ← EMPTY
```
⇒ ⛔⛔ **`MapSet.subset?(∅, ∅)` IS ALWAYS TRUE, SO `attenuates?` IS VACUOUS FOR
SUBTREE SCOPES.** ⚠️ **That empty-set placeholder is documented as safe
*precisely because subtree certs were leaf-only* — and this change REMOVES THE
PREMISE THAT MADE IT SAFE.**
⇒ ⭐⭐ ***A relaxation turns a documented-safe placeholder into a load-bearing
one that cannot bear load.*** **Without an explicit check, mint would happily
issue a cert naming a FOREIGN root.**
⚠️ **The system still fails closed — verify rejects it with
`:subtree_scope_root_mismatch` — but *a mint that emits unusable certificates is
a footgun*, and it would look like a working feature until someone tried the
cert.**

## ⛔ Acceptance — six arms, FIVE of them RED, each attempting the forbidden act

1. ✅ **Same-root child with NARROWED verbs and a TIGHTER window → mints,
   verifies, and authorizes in scope.**
2. ⛔ **A child naming a DIFFERENT root → REFUSED AT MINT**, not merely at
   verify. ⭐ **This is the new explicit check; demonstrate it red.**
3. ⛔ **A child WIDENING verbs → `{:not_attenuation, …}`.** *Existing behaviour —
   asserted so the relaxation cannot regress it.*
4. ⛔ **A child with a LOOSER `not_after` → refused.**
5. ⭐⭐ **A link LACKING `:delegate` → `:delegation_not_permitted`.** ⇒ **THIS IS
   THE POSITIVE CONTROL THAT THE RELAXATION DID NOT OPEN THE GATE GENERALLY.**
   ⛔ *Without it, "same-root delegation now works" is indistinguishable from
   "delegation now works".*
6. ⛔ **MIXED scope types anywhere in the chain → `:mixed_scope_type_chain`.**

⭐ **PRINT EVERY ARM'S OUTCOME AND SHOW THE PAIRS DIFFER.** ⛔ ***If two arms
defined to differ produce the same value, the arms did not run.***

## ⛔ TWO THINGS EXPLICITLY OUT OF SCOPE — the round must not grow into them

- **D2, subtree ROOT NARROWING** (*"B's root is a descendant of A's"*).
  **DEFERRED, and genuinely hard:** ⚠️ **the document tree is MUTABLE, so
  descendant-ness is not a fact about the cert but about the tree AT THE MOMENT
  OF THE ACT.** ⇒ *It would have to be verify-time per act, never frozen at
  mint, or a later move silently widens or escapes a grant.* ⛔ **If you find
  yourself needing it, STOP AND REPORT.**
- **A per-cert DEPTH COUNTER — NOT NEEDED.** ⭐ **Delegation is already gated by
  the `:delegate` verb, so "depth 1" is expressed by WITHHOLDING it**, with
  `@max_depth 64` as the backstop.

## ⚠️ THE SANDBOX CANNOT SIGN — plan for it, do not discover it

**`node_signing_key` is MASKED in your fence** ⇒
`Commonplace.Crypto.NodeIdentity.signing_context/0` FAILS and no node-signed
write succeeds. ⭐ **Use the injectable `opts[:signing_context]` seam** —
`Trust.SubtreeCarveTest` and the `Identity.*` modules are worked examples.

## Suites

⛔ **Run `bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK; take the
count from the tool, not from this brief.** **On-main as of writing: `3519 / 0`
at seed 117514, `origin/main` `64b2be5a`.**
⚠️⚠️ **BUILD FROM THAT BASE.** *A brief asserting a count its base cannot produce
cost a round tonight.*
⚠️ **The suite now prints `GLOBAL STATE LEAK DETECTOR: <n> divergence(s) —
ADVISORY, not a failure` and a line saying its positive control did not run.
THAT IS EXPECTED AND IS NOT A FAILURE.** ⛔ **If it ever appears as a FAILURE,
that is a finding.**
⚠️ **Known reds, by TEST and MECHANISM — a module-scoped exemption absorbs new
failures, which already happened once today:**
- **`CX-kx6d`** — `GitBridge.ServerTest` *"filters: __ / nosync / presence …
  across two cycles"*, teardown check-then-act (`Process.whereis` then
  `GenServer.stop` → `no process`).
- **unticketed** — `GitBridge.ServerTest` *"push: failure to an unreachable
  remote … retries"*, `{:error, :already_registered}` from
  `WorkspaceFixture.complete_workspace!/2`.
- **`CX-s9kc`** — `chat_view_compute_supervisor_test.exs`, non-deterministic.
⛔ **ANY OTHER failure — or either of those with a DIFFERENT error shape — IS
YOURS. Say which you saw, VERBATIM.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`
  — workspace-relative, NOT repo-root, NOT `data/`.*
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES.**
  ⚠️ *Seven rounds in a row have produced their best result by correcting their
  brief rather than satisfying it — including two tonight that caught the
  author's own contradictions.*
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to let `attenuates?`
  stand in for the same-root check, or to widen the relaxation beyond same-root.
- ⭐⭐ **WHAT WAS THIS COPIED FROM, AND WHAT HAS BEEN COPIED FROM THIS?**

## Review criteria

The same-root check added EXPLICITLY rather than leaning on vacuous subtree
attenuation; a foreign root refused AT MINT and demonstrated red; verb-widening
and window-loosening still refused; the missing-`:delegate` arm proving the gate
did not open generally; mixed scopes still refused; all arms printed and shown to
differ; and D2 / depth-counter untouched.

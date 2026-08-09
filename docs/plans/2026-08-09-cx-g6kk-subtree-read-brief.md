# BUILD BRIEF — CX-g6kk: a `{:subtree, R}` cert cannot authorize a READ

**For:** Sol (codex)
**Ticket:** **CX-g6kk** (p2/bug)
**Worktree:** `/home/jes/sol-g6kk/wt` · **branch:** `sol/cx-g6kk`
**Run log:** `/home/jes/sol-g6kk/sol-run.log` (beside the worktree)

---

## 0. Environment contract (standing)

Named worktree off **current** `origin/main`; ⛔ leave changes **UNSTAGED**, no
`git add`, no commit, no push; suites via `bin/cp-test-guard`, **one at a
time**; ⚠️ rc from the command itself, **never a pipe**; ⚠️ **a count from a
piped listing is not a count**; ⚠️ **the default is not the value** — read
constants at the call site.

⛔ Each `exec` gets a **fresh PID namespace** — redirect long runs to a file
and read the file, never poll `ps`/`pgrep`. ⚠️ **A fresh worktree needs
`mix deps.get` before anything compiles.**

⭐ **The fence's red-is-expected property is in the runner header — read it
there.** This brief's job is only to say **which criteria are fixture-anchored
and which are live-anchored.** See §5.

## 1. The defect

`Commonplace.Trust.cert_grants_read?/5` (trust.ex ~:583):

```elixir
with {:ok, leaf} <- fetch_cap(store, cid),
     {_uuid, audience_pub} <- leaf.audience,
     true <- pub != nil and audience_pub == pub,
     {:ok, %{verbs: verbs, scope: {:docs, docs}}} <- VerifyChain.verify_chain(cid, anchor_keys(cfg), store) do
  :read in verbs and target_uuid in docs
else
  _ -> false
end
```

⇒ **`{:docs, docs}` is the ONLY scope shape the pattern admits.** `subtree`
appears **zero** times in the function. **A `{:subtree, _}` cert falls straight
through to `else -> _ -> false`.**

The **write** side has the clause it needs (trust.ex:413-418):

```elixir
defp write_scope_covers?({:docs, docs}, target_uuid, _store), do: target_uuid in docs
defp write_scope_covers?({:subtree, root}, target_uuid, store),
  do: doc_zone(target_uuid, store) == root
defp write_scope_covers?(_other, _target_uuid, _store), do: false
```

⇒ ⭐ **SUBTREE SCOPE IS ENFORCED FOR WRITE AND STRUCTURALLY INVISIBLE FOR
READ.** The grammar shipped in CX-4u03 A1 (@f842fda, @b168f79); only half of
it is reachable.

## 2. ⛔ WHY THIS IS WORSE THAN A MISSING FEATURE — and what the red must show

**The cert mints fine. `verify_chain` SUCCEEDS. The audience binding HOLDS.**
And it authorizes nothing, **with no error naming the scope mismatch.**
⇒ ⭐ **A silent `false`, INDISTINGUISHABLE FROM "not permitted."**

⛔ **THEREFORE: A POST-FIX GREEN PROVES NOTHING ABOUT WHAT IT REPLACED.** A
test that merely asserts *"a subtree read is authorized"* would pass after the
fix and say nothing about the failure mode being removed — **because the thing
being removed looks exactly like a legitimate denial.**

⇒ ⭐ **THE RED MUST EXHIBIT EVERY PART WORKING AND THE WHOLE GRANTING
NOTHING:**
1. the `{:subtree, R}` `:read` cert **mints** (assert on the returned cap),
2. `VerifyChain.verify_chain/3` **returns `{:ok, _}`** for it (assert it
   directly, separately),
3. the **audience binding holds** (the presenting pubkey == `leaf.audience`
   pubkey),
4. and the read is **STILL DENIED**.
**Paste that red.** ⛔ Steps 2 and 3 asserted **separately** are what make the
red mean "the scope shape was rejected" rather than "something failed."

## 3. The fix — two halves, and one alone is a trap

1. **`cert_grants_read?/5`**: add a `{:subtree, _}` case, mirroring
   `write_scope_covers?/3`'s use of `doc_zone/2`.
2. **`Trust.Read.grant/4`**: it hardcodes
   `claim = %{verbs: [:read], scope: {:docs, [target_uuid]}}` — add a scope
   parameter so a subtree read can be **minted** at all.

⛔ **HALF-FIX CONTROL (required):** ship **② without ①** and show a test goes
red — **the cert mints, verifies, binds, and grants nothing.** ⭐ **That is the
state this ticket must not leave behind**, and it is the state a naive reading
of the ticket title produces.

⚠️ **DO NOT relax `check_subtree_leaf_only/2` (subtree certs are LEAF-ONLY in
M2 — no re-delegation) or `check_no_code_doc_in_scope/2` to make anything
pass.** ⭐ **If a test only goes green by loosening one of those, the test is
wrong, not the guard.**

## 4. Acceptance

1. **The red from §2, pasted, with steps 2 and 3 asserted separately.**
2. **The half-fix control from §3, pasted.**
3. Green after both halves: a subtree `:read` cert authorizes a read of a doc
   **inside** R…
4. …and ⛔ **does NOT authorize a doc OUTSIDE R.** ⭐ **A scope that grants
   everything would pass criterion 3.** This is the tamper half.
5. **`{:docs, _}` reads still work** — assert an existing doc-scoped read is
   unaffected.
6. `mix compile --warnings-as-errors` rc=0. Named suites, **baselined on main
   first**, one at a time, with both counts:
   - `apps/commonplace/test/commonplace/trust`
   - ⭐ `apps/commonplace/test/commonplace/trust/subtree_carve_test.exs`
     **already exists** — check it for a harness before building one.

## 5. ⭐ FIXTURE-ANCHORED vs LIVE-ANCHORED — which is which

⭐ **THE ENTIRE RED IS FIXTURE-ANCHORED AND THAT IS SUFFICIENT.**
`verify_chain/3` takes `anchor_keys(cfg)` — **an arbitrary set of pubkeys** —
and existing tests already pass `MapSet.new([root.pub])` from a fixture
(`verify_chain_revocation_test.exs:77`). ⇒ **Nothing about this defect depends
on the anchor being real: it is a PATTERN-MATCH SHAPE.** A fixture chain is a
real chain verification.

⇒ **So every criterion in §4 is runnable in the sandbox.** ⛔ **Do not report
any of them as blocked on a live anchor.**

⚠️ **Still owed and NOT in scope:** a live-anchor exercise after the next
deploy. **Name it as owed; do not attempt it.**

## 6. Out of scope

- Anything about the remote-worker/EC2 design beyond this defect.
- The delegation root, the anchor set, agent identity.
- Any other defect: **report it, don't fix it.**

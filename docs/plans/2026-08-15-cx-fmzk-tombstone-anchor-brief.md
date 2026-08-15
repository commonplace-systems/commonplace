# CX-fmzk build brief: verify the signer against a configured trusted set

> **The work's ticket is `CX-fmzk`.** Base: **the commit that adds this brief**
> — ⚠️ *not a sha; committing a brief moves HEAD past any sha it records.*

## ⛔⛔ THE DEFECT — verified at source before briefing

```elixir
# apps/commonplace/lib/commonplace/store/sla_tombstone.ex — grep `defstruct`
signer_public_key   # 32 bytes, A FIELD ON THE STRUCT

# grep `verify_signature`
:crypto.verify(:eddsa, …, [tombstone.signer_public_key, :ed25519])
```

⇒ ⭐⭐⭐ **`verify_signature` TAKES THE KEY FROM A FIELD ON THE STRUCT IT IS
VERIFYING.** ⇒ ⛔ ***IT IS NOT A WEAK CHECK. IT IS A VACUOUS ONE*** — **a check whose evidence is supplied by its own input.** ⚠️ *A tombstone whose `signer_public_key` is ANY keypair passes `validate_shape`,
`verify_id` AND `verify_signature`, because the check reads the key from the
record it is checking. Internal consistency is all that is established.*

⭐ **The record proves INTEGRITY (it was not altered after signing). It does not
establish AUTHORIZATION (that the signer was permitted to evict).** *Measured by
`I4`'s round: a tombstone signed by an unrelated keypair returned `:ok`.*

⭐⭐ **WHY IT MATTERS: a tombstone's JOB is to distinguish EVICTED-PER-POLICY from
MISSING.** ⇒ ⛔ ***If any signer's tombstone is accepted, the reassuring
explanation becomes the cheap one to produce, and the distinction the record
exists for stops holding.***

## The round is TWO parts, and ⓑ does not wait on ⓐ

### ⓐ MEASURE REACHABILITY — and record it either way

**Three call sites, none touched by `I4`:**
```
apps/commonplace/lib/commonplace/store/commit_store.ex   # grep `SlaTombstone.verify`
  the store_sla_tombstone handle_call  — writes AND indexes the tombstone
                                         against every commit_id it names
  the read path                        — returns {:ok, tombstone} on :ok
```
⇒ **Can an untrusted principal reach `store_sla_tombstone`, or is it gated
upstream?** ⭐ **Plan expects this to be minutes.** ⛔ **RECORD THE ANSWER EITHER
WAY — it is the round's finding regardless of which way it lands.**
⚠️ **It determines SEVERITY. It does NOT determine whether ⓑ ships.**

### ⓑ FIX THE VERIFICATION REGARDLESS OF ⓐ

⛔ **Plan's ruling, verbatim: *reachability determines URGENCY, not
CORRECTNESS.*** ⇒ ⭐ ***A vacuous check that happens to be unreachable today is a
vacuous check with a RE-ARM CONDITION*** — **and this codebase has been bitten by
protection-by-accident three times in the last fortnight.**

**Verification must check the signer against a TRUSTED EVICTION-SIGNER ANCHOR
rather than against a key supplied by the artifact.**

⚠️⚠️ **THE ANCHOR DOES NOT EXIST YET, AND YOU MUST NOT INVENT ONE.** *`I4`
already recorded it as owed: "production must supply the trusted eviction-signer
anchor."* **SAME MISSING PIECE, TWO TICKETS.**
⇒ ⭐⭐ **LAND THE ANCHOR-**CHECKING** FORM AND NAME THE ANCHOR'S PROVISIONING AS A
PRECONDITION.** ⛔ **With no anchor set configured, it must REFUSE LOUDLY —
`no eviction anchor configured`-shaped — rather than verify against nothing.**
⇒ ***A fix that silently falls back to the embedded key is the same vacuous
check wearing a fix's clothes.***
⭐ **`I4`'s reader is the worked example of the check itself:** grep
`untrusted_tombstone_signer` in
`apps/commonplace/lib/commonplace/runner/deployment_record.ex`.

## ⛔ Acceptance — artifacts, red-first

1. ⭐⭐ **RED FIRST — a fixture in the state the check must reject: build a
   tombstone whose `signer_public_key` is a DIFFERENT keypair from the
   configured trusted signer, and SHOW the CURRENT `SlaTombstone.verify/1`
   RETURNS `:ok`.** ⛔ **Verbatim output.** *This is the arm the ticket exists for.*
2. ⭐⭐ **AFTER THE FIX, THE SAME FIXTURE IS REFUSED AND THE REFUSAL NAMES WHY.**
   ⛔ **The same fixture — not a second, weaker one.**
3. ⭐⭐ **THE QUIET HALF: a legitimately-signed tombstone from a TRUSTED signer
   still verifies, and the existing `sla_tombstone_test.exs` arms still pass.**
   ⚠️ ***A fix that makes everything fail passes arm 2 and is worse than the
   bug.***
4. ⭐ **NO ANCHOR CONFIGURED ⇒ LOUD REFUSAL**, demonstrated, not asserted.
   ⛔ **Show it does NOT fall back to the key on the record.**
5. **`ⓐ`'s answer, stated plainly with what you read to get it** — *"gated at X"*
   or *"reachable from Y"*, naming the path. ⛔ **"Probably gated" is not an
   answer.**
6. ⭐ **PRINT THE ARMS' OUTCOMES AND SHOW THEY DIFFER.** ⛔ ***If two arms defined
   to differ agree, the arms did not run.***
7. **Lands as files with their own counts from the tree.**

## ⚠️ THE SANDBOX CANNOT SIGN — plan for it, do not discover it

**`node_signing_key` is MASKED in your fence** ⇒
`Commonplace.Crypto.NodeIdentity.signing_context/0` **FAILS and no node-signed
write succeeds.** ⭐ **Use the injectable `opts[:signing_context]` seam** — *the
`I1`–`I4` identity modules and `sla_tombstone_test.exs` are worked examples of
fixture signing contexts.* ⛔ **A round assuming ambient node signing produces a
confident wrong diagnosis ("signing is broken"), not a stuck run.**
⚠️ **A full suite DOES run in a worktree despite the baseline block saying "no
repo `deps/`" — S71 ran 3506 tests inside one.**

## Suites

⛔ **Run `bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK; read the
`BEFORE` line.** **On-main count as of this brief: `3517 tests, 0 failures`,
seed 117514.** ⚠️ **Take the number from the tool's own block — it has moved
three times today.**
⚠️ **`CX-s9kc`: sandbox `chat_view_compute_supervisor_test.exs` flake,
non-deterministic, NOT yours.** ⚠️ **`CX-0ktk` was a seed-117514 ordering failure
at population 3510; that population is gone and it should not appear.** ⛔ **If
`MUD.RoomVisibilityTest` fails, say so — it would be news.** **Anything else IS
yours.**
⚠️ **In a fresh worktree `mix format --check-formatted` exits `rc=1` with
"Unknown dependency :phoenix" — the SAME CODE as "files are not formatted".**
⇒ **Never branch on `rc` alone: a real format failure LISTS FILE PATHS.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`
  — workspace-relative, NOT repo-root, NOT `data/`.*
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.**
- ⭐ **Verify by RE-READ, not by the write returning.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES.**
  ⚠️ *The last three rounds' most valuable contributions were all corrections to
  their briefs.*
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to invent an anchor set,
  or to let the no-anchor case fall back to the record's own key "for compatibility".
- ⭐⭐ **WHAT WAS THIS COPIED FROM, AND WHAT HAS BEEN COPIED FROM THIS?** ⚠️ *If
  any other verifier in this tree takes its key from its own subject, that is
  the same defect and worth naming even if you do not fix it.*

## Review criteria

The untrusted-signer fixture shown accepted BEFORE and refused AFTER, same
fixture; the refusal naming why; the quiet half preserved with existing arms green; a loud refusal
when no anchor is configured with no silent fallback; `ⓐ`'s reachability answer
stated with the path that supports it; the anchor's provisioning named as a
precondition rather than invented; and arms printed and shown to differ.

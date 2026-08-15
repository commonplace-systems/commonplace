# I3 build brief: class ratification, and the pin that a `resolve/1` throws away

> **Ticket/row: `I3`** of the §14 identity slice
> (`commonplace-plan:docs/plans/2026-08-15-identity-slice-decomposition.md`).
> Base: **the commit that adds this brief** — ⚠️ *not a sha; committing a brief
> moves HEAD past any sha it records.*
>
> ⛔⛔ **THIS IS A COMPONENT LANDING, NOT THE SLICE.** **NO ROUND PUBLISHES A
> "SLICE WORKS" CLAIM UNTIL `I5` RUNS.** *`I5` is the two-deployment proof and it
> is not yours.*

## Build

**Finding 3.** A steward ratifies a **class** once — mission template, scope
envelope, auditor role, escalation parent, SLA — and spawns of that pinned
`class_ref` inherit it. **Out-of-class requests refuse and escalate.**

`I1` built the root (`genesis` carries `class_ref`); `I2` built the spawn
ceremony (it copies `class_ref` through verbatim, three sites, as an opaque
value). **You are adding the ratification check between them.**

## ⭐⭐ THE ENABLING FACT — verified in the tree before briefing

**`Commonplace.Document.DocRef` ALREADY carries a version pin.** Its own
moduledoc, verbatim:

```
Format: `path:uuid@cid`
  cid — optional commit ID (hex-encoded, for pinning to a specific version)
  notes/todo.txt:<uuid>            — latest version
  notes/todo.txt:<uuid>@a1b2c3d4   — pinned version
defstruct [:path, :uuid, :cid]
```

⇒ ⭐⭐ **A pinned class version is an EXISTING FORMAT, not a thing you invent.**
✅ *Same shape as `I1`, where `records` being a DocRef map made "no new authority
code" reachable rather than aspirational.*

⛔ **NO NEW VERSIONING CODE. A diff that introduces a parallel class-version
scheme beside `DocRef`'s `@cid` FAILS THIS ROUND ON ITS FACE** — for the same
reason `I1` refused a record-type check: a second mechanism beside the substrate's
own is a second system to keep honest.

## ⛔⛔ AND HERE IS THE TRAP, ALSO VERIFIED IN THE TREE

```elixir
def resolve(%__MODULE__{uuid: uuid}) when is_binary(uuid) and uuid != "" do
  {:ok, uuid}          # ← THE CID IS DISCARDED. SILENTLY. NO ERROR.
end
```

⇒ ⛔⛔ **A `class_ref` CAN CARRY A PERFECTLY CORRECT PIN AND STILL FLOAT TO
LATEST, the moment anything resolves it.** ⚠️ **`resolve/1` does not warn, does
not error, and returns `{:ok, …}` — the pinned and unpinned refs become the same
value with no observable difference at the call site.**

⭐⭐⭐ **THEREFORE: A CID PRESENT IN THE REF IS NOT EVIDENCE THE PIN IS ENFORCED.
It is a field an unpinned ref also satisfies once `resolve/1` has run.** ⇒ ⛔
***DO NOT SATISFY ARM 3 BY ASSERTING THE `class_ref` STRING CONTAINS AN `@cid`.***
*That is shape equality, and this week shipped two defects that passed exactly
that way.*

## ⛔ Acceptance — all artifact-checkable, and arm 3 is the ticket

1. **IN-CLASS SPAWN COMPLETES WITH NO STEWARD IN THE LOOP.** ⭐ *Show the
   absence of the steward step as an OBSERVED outcome, not as "we did not call
   it" — an unreached branch and an absent one look identical.*
2. ⭐⭐ **AN OUT-OF-CLASS SPAWN REFUSES, AND THE REFUSAL NAMES **WHICH FIELD**
   LEFT THE CLASS.** ⛔ **"Refused" alone fails this arm.** *`I2` set the
   standard already: it named `:spawn_request_conflict` rather than refusing
   generically, and that is what made the refusal actionable.*
3. ⭐⭐⭐ **AMEND THE CLASS, THEN SHOW AN EXISTING CHILD IS **NOT** RETROACTIVELY
   RATIFIED — BY EFFECT.** ⇒ **The proof is a BEHAVIOURAL DIFFERENCE after the
   amendment: the child still answers by the pinned version, and a NEW spawn
   against the amended class answers by the new one.** ⛔ **Print both and show
   they DIFFER.**
   ⚠️ **This is the arm `resolve/1` will silently defeat.** ⭐ *If you find the
   amendment DOES propagate, that is a finding, not a failure — report it with
   the value you observed and stop.*
4. ⭐⭐ **RED-FIRST, AND IT MUST BE CONSTRUCTED, NOT REPRODUCED.** *There is no
   existing ratification path, exactly as there was no existing spawn path in
   `I2`.* ⇒ **Build the naive version (class_ref resolved to a bare uuid), show
   the amendment DOES leak into an existing child, THEN fix it and show it does
   not.** ⛔ ***A pin verified only against an un-amended class proves nothing
   about the branch that matters.***
5. ⭐⭐ **PRINT EVERY ARM'S OUTCOME AND SHOW THE PAIRS DIFFER.** ⛔ ***If two arms
   defined to differ produce the same result, the arms did not run.*** ⚠️ *Days
   old: three arms silently ran the same check via a mistyped env var and all
   returned 0.*
6. **Lands as files with their own counts from the tree.**

## ⚠️ THE SANDBOX CANNOT SIGN — plan for it, do not discover it

**Standing property: `node_signing_key` is MASKED in your fence, so
`NodeIdentity.signing_context/0` FAILS and NO node-signed write can succeed
there.** ⇒ ⛔ **A round that assumes ambient node signing produces a confident
wrong diagnosis ("signing is broken"), not a stuck run.**
⭐ **Use the injectable seam the codebase already has: `opts[:signing_context]`,
threaded `start_link/1` → `init/1`.** *`Bursar` and `Frontier.Server` are the
worked examples; **`I1` and `I2` are now the closer ones — read them first.***
⭐ ***"Tested against fixtures, one assertion needs a real anchor" beats "we
couldn't test it."*** ⛔ **If an assertion needs a real anchor, NAME IT AS OWED.**

## Suites

⛔ **Run `bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK; read the
`BEFORE` line.** **Host at `e8d9053c`, measured for this brief:**

```
seed 1        3510 tests, 0 failures     ← green
seed 424242   3510 tests, 0 failures     ← green
seed 117514   3510 tests, 1 FAILURE      ← CX-0ktk, NOT YOURS
```

⚠️⚠️ **`bin/cp-suite-baseline` DEFAULTS TO SEED `117514`, SO THE TOOL WILL
PROBABLY HAND YOU A RED. IT IS `CX-0ktk` AND IT IS NOT YOURS:**
`Commonplace.MUD.RoomVisibilityTest` — *"the owner's own look on their gated room
renders normally (self-read)"* — rendering `"(this place has no description)"`.
⭐ **Pre-existing ORDERING CONTAMINATION, attributed before this brief was
written: green at other seeds, green with the identity tests withdrawn at the
SAME code, green in isolation, red on both host and sandbox at `117514`.**
⇒ ⛔ **If `RoomVisibilityTest` is the ONLY failure, it is `CX-0ktk`. ANYTHING
ELSE IS YOURS.** ⭐ **Cross-check with a second seed — a green at seed `1` tells
you your work is clean far more cheaply than arguing about `117514`.**

⚠️ **Two sandbox runs have disagreed historically — one `3505/2`
(`chat_view_compute_supervisor_test.exs`), the next `3505/0`; filed `CX-s9kc`,
non-deterministic, NOT yours.** ⛔ **Anything outside these two named tickets IS
yours.**

⛔⛔ **AND DO NOT "FIX" `CX-0ktk` BY MAKING YOUR OWN TESTS QUIETER.** ⭐ *Adding
tests reshuffles the deck at a fixed seed; a round that isolates its way to green
moves the deck BACK, leaves the leak in place, and the ledger records it as
fixed.* ⇒ **If your work perturbs it, SAY SO — that is a finding, not a mess to
tidy.**

⚠️ **In a fresh worktree `mix format --check-formatted` exits `rc=1` with
"Unknown dependency :phoenix" — the SAME CODE as "files are not formatted".**
⇒ **Never branch on `rc` alone: a real format failure LISTS FILE PATHS.**
⭐ **`bin/cp-format-changed` gates only files a commit touches — format what you
add.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`
  — workspace-relative, NOT repo-root, NOT `data/`.*
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.**
- ⭐ **Verify by RE-READ, not by the write returning.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES
  rather than satisfying it.**
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER** — *in your
  report and in any comment you leave.*
- ⭐ **Report the NEAR-MISS** — especially any temptation to prove the pin by
  inspecting the ref string rather than by amending the class and observing the
  effect.
- ⭐⭐ **WHAT WAS THIS COPIED FROM, AND WHAT HAS BEEN COPIED FROM THIS?**
  *`I3`'s prospective parent is `I2`. Answer it as a CHAIN, as `I2` did.*

## Review criteria

The pin expressed through `DocRef`'s existing `@cid` with no parallel versioning
scheme; the out-of-class refusal naming the offending field; the amendment
non-propagation proven **by observed behavioural difference** rather than by the
presence of a cid; a constructed red-first showing the naive version DOES leak;
all arms printed and shown to differ; and `resolve/1`'s cid-discarding addressed
explicitly rather than incidentally.

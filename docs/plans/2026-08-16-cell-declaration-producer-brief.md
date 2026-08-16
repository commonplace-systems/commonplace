# A spawned cell writes a declaration — and the writer holds nothing

> **Ruled by `commonplace-plan`, joining arc §4e.** Base: **the commit that adds
> this brief** — ⚠️ *not a sha.*
>
> ⛔ **THIS ROUND IS THE PRODUCER ONLY. The reconciler is the next rung.**
> *Two holes were named; this closes one. The producer's unknown is "can a
> declaration be written by something unprivileged". The reconciler's unknown is
> "what shape does the loop take without foreclosing the general form" — a
> different question, and one-unknown-per-rung is this arc's own discipline.*

## What exists, measured — do not re-derive from a picture

**Six audits on this arc changed what a round would have built. Every fact below
is measured, with its control.**

```
✅ the launcher RUNS pods, isolated, killable two-sided, reaped
✅ a pod mints and signs its OWN key; the durable key is unreadable from inside
✅ CX-kacr gates the launcher: it refuses without `dedicated_runner_service: true`
✅ Cell.Manifest         create/2 · read/2 · amend · validate · encode · decode
✅ RunRecipe             the DECLARATION PATTERN, see below
✅ AgentKeys.ensure/2    mints a child keypair into a secret store
✅ the spawn receipt     A PERSISTED DOCUMENT at a derived uuid, carrying
                         child_uuid · name · request_digest · status · public_key

⛔ NOTHING writes a declaration for a reconciler to find.
⛔ NOTHING reads one.       ← the next rung, NOT this one
```

⚠️ **A correction that cost a re-measure and must not be re-inherited: the
provisioner's `Manifest.read` is a VERIFY-BY-RE-READ OF ITS OWN WRITE, three
lines after `Manifest.create`. It is NOT consumption of a declaration.** ⛔ *A
call site is not a dataflow.*

## ⛔ What to build

**① A CELL DECLARATION: a document saying WHO A CELL IS, written after a spawn.**
**② A PUBLIC READER on `SpawnCeremony` returning the receipt's public fields.**

### ⭐⭐ THE SHAPE IS ALREADY WRITTEN IN THIS SUBSYSTEM — COPY IT

**`Commonplace.Runner.RunRecipe`, from its own moduledoc:**

> *"The six-field, repository-owned declaration… this module **never infers,
> provisions, starts, or probes anything**."*

⇒ ⭐ **That discipline IS the requirement. Follow `RunRecipe`'s shape:
`validate/1` · `encode/1` · `decode/1`, and a module that DECLARES AND DOES
NOTHING.**
⛔ **PATTERN TO COPY, NEVER THE DOCUMENT TO REUSE** — `RunRecipe` says how to RUN
AN APPLICATION; this says WHO A CELL IS. Different subject, same discipline.

### ⛔⛔ THE PRODUCER'S PRIVILEGE IS THE POINT, AND IT IS CHECKABLE

**The spawn mints (`AgentKeys.ensure` at `spawn_ceremony.ex:208`) and is already
operator-gated by the parent signing context. The declaration needs NOTHING the
spawn holds — the child's PUBLIC key is that call's return value and is already
persisted in the receipt.**

⇒ ⭐⭐⭐ **THE PRODUCER MUST NOT BE THE SPAWN.** *A declaration-writer placed
inside the ceremony inherits secret-store authority it never uses — a privilege
granted by proximity, which is the kind nobody ratified.*

⇒ **TWO CHECKS, BOTH GREPS, BOTH REVIEWABLE BY ANYONE WITHOUT THIS CONVERSATION:**
```
the producer MUST NOT appear in the `AgentKeys.ensure` caller list
    (currently 4: spawn_ceremony · loom_bridge · presence/identity ×2)
the producer MUST touch NO SLOT
    (priv_slot/pub_slot refs outside agent_keys.ex: 0)
```
⚠️ **That list is a RECORD, NOT A BOUND — a fifth legitimate caller may appear.
What the check catches is THE PRODUCER appearing, not the list growing.**
⛔ ***If you find yourself granting the producer a capability "just to make it
work", STOP AND REPORT IT.*** *That is the signal, and it is the same shape as a
round refusing to weaken a gate to manufacture an artifact.*

### ⛔ THE READER — NAMED FIELDS, NEVER THE DOCUMENT

**Measured: `receipt_uuid/2` and `read_receipt/2` are BOTH `defp`, and
`SpawnCeremony`'s public surface is `start_link · spawn_child ·
authorize_action · deployment_permitted? · write_record`. No accessor exists.**
⇒ ⭐ ***THE DOCUMENT OUTLIVES THE CALL; THE MEANS OF FINDING IT DOES NOT.***

⛔⛔ **THE READER RETURNS NAMED PUBLIC FIELDS, NOT THE RECEIPT.** ⇒ ***A reader
that returns the whole document grants everything that document WILL EVER
CARRY*** — **tomorrow's field arrives already exported and nobody decides that.**
⭐ *Bounded by enumeration, not by today's contents.*

⛔ **AND DO NOT EXPORT `receipt_uuid`.** ⇒ ***HAND BACK A READER, NEVER AN
ADDRESSING RULE.*** *A duplicated derivation has N owners and drifts — the
copy-chain defect at an API boundary.*

### ⛔⛔ ORDERING — REQUIRE THE STATUS, NEVER TEST FOR NIL

**The ceremony advances `proposed → key_minted → …`. A receipt read at
`proposed` has NO public key.**

⇒ ⛔ ***TESTING THE KEY FOR NIL IS AN ABSENCE SCAN — it cannot distinguish "no
key" from "no key YET."*** ⇒ ⭐⭐ **REQUIRE `key_minted` AND REFUSE BY NAME
OTHERWISE.** *That is the positive declaration, identical to `CX-kacr`'s launcher
marker* — ⭐ **and THE MARKER ALREADY EXISTS: the ceremony's own status field.
Nobody adds one; read the right thing.**

## ⛔ Acceptance — artifacts

1. **A declaration document type with `validate`/`encode`/`decode`, which
   INFERS, PROVISIONS, STARTS AND PROBES NOTHING.**
2. **A producer that writes it after a spawn, reading the receipt through the new
   public reader.**
3. ⭐⭐ **THE PRIVILEGE CHECK, RUN AND REPORTED: the producer appears in NEITHER
   the `AgentKeys.ensure` caller list NOR any slot reference.** *Print both greps.*
4. ⭐ **The reader returns NAMED FIELDS. Show the list. `receipt_uuid` is NOT
   exported.**
5. ⭐⭐ **RED FIRST, and it is the ordering arm: a receipt at `proposed` must be
   REFUSED BY NAME, not silently produce a declaration with a nil key.** ⛔ *Show
   the refusal, and show it differs from the success case.*
6. **Existing spawn-ceremony tests still pass. PER-FILE counts AND the suite
   total from the tool's own block, plus the POPULATION DELTA BY HAND.**

## ⚠️ THE SANDBOX CANNOT SIGN AS THE NODE

**`node_signing_key` is MASKED** ⇒ `Crypto.NodeIdentity.signing_context/0` fails.
⭐ **Use fixture signing contexts via `opts[:signing_context]`** — `spawn_child`
already requires one (`Keyword.fetch!(opts, :signing_context)`).

## Suites

⛔ **`bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK.** **On-main:
`3535 / 0`, seed 117514.** ⚠️ **The stamp is `[stamp-v2]` and as of `9cdde6af` it
sees `apps/*/test/` AND `bin/` — including itself.**
⚠️⚠️ **THE LEAK DETECTOR'S OBSERVED VALUES ARE A RECORD, NOT A BOUND.** ⛔ **A
value outside the list is NOT a finding; only `FAILURE` rather than `ADVISORY` is.**

### ⚠️ Known-nondeterministic, by TEST and MECHANISM — NOT yours

```
GitBridge.ServerTest — "GenServer.stop → no process" teardown check-then-act.
  THREE distinct tests, clean-tree reproduced. BY MECHANISM.
  ⛔ Any OTHER error shape in that module is YOURS.
Runner.LauncherTest — "pod cannot read a canary injected by its launching BEAM".
  Environment-sensitive (CX-kacr); fails as `canary_result == ""`. Passes in
  isolation. ⛔ A DIFFERENT error shape there is yours.
```

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`.*
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.**
- ⛔ **Do not select processes by name or argv pattern. Use captured pids.**
- ⭐⭐ **REDIRECT TEST OUTPUT TO A FILE AND GREP THE FILE.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES.**
  ⚠️ *Six audits on this arc found the brief's own premise wrong — including one
  that corrected an audit from fifteen minutes earlier. Check this one too.*
- ⭐ **VERIFY BY RE-READ, not by the write returning.**
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to place the producer
  inside the ceremony, to return the whole receipt, or to test the key for nil.
- ⭐⭐ **WHAT WAS THIS COPIED FROM, AND WHAT HAS BEEN COPIED FROM THIS?**

## Review criteria

A declaration type following `RunRecipe`'s declare-and-do-nothing discipline; a
producer outside the spawn that reads the receipt through a new public reader
returning NAMED fields; both privilege greps run and reported clean;
`receipt_uuid` not exported; the ordering arm refusing a `proposed` receipt BY
NAME and shown distinct from success; existing tests green; per-file counts, the
suite total, and the population delta by hand.

# I5 — the two-deployment proof (§14 itself)

**Run 2026-08-15 on the host by commonplace (not Sol: composition and
judgement).** Base: `e9d23043` (`I1`–`I4` all merged).

⭐⭐ **THIS IS THE FIRST POINT IN THE ARC AT WHICH A "SLICE WORKS" CLAIM IS
PERMITTED**, and the claim is bounded below by what was actually run.

## What was run

Four separate OS processes against one CubDB store. **CubDB is single-opener, so
the separation is STRUCTURAL rather than a sequencing convention** — A must exit
before B can open the store at all.

```
### A                       pid 1932046
A_IDENTITY_ROOT             an I1 root with a governed `understanding` record
A_UNDERSTANDING_AT_A        %{"state" => "fresh", "written_by" => "deployment-a", "zone" => …}
A_RECORD_COMMIT             an I4 append-only deployment record
                            + a finding and a yield PROMOTED BY REFERENCE
A_EXITS_NOW                 true

### B                       pid 1932231   ← DIFFERENT OS PROCESS
B_RECORDS_FOUND             1
B_RESOLVED_YIELD_FROM_STORE %{"next_step" => "resolve the finding and record understanding", …}
B_UNDERSTANDING_BEFORE      written_by "deployment-a"
B_UNDERSTANDING_WRITE       :ok      ← via the parent→child CERT, child NOT a trusted identity
B_UNDERSTANDING_AFTER       %{"state" => "resolved", "written_by" => "deployment-b",
                              "resolved_from_yield" => "resolve the finding and record understanding"}
B_RESULT                    :SUCCEEDED

### MUST-FAIL CONTROL       pid 1932448   ← identical inputs, store that never saw A
B_RECORDS_FOUND             0
B_RECONSTRUCTION            :impossible_no_record_of_a
B_RESULT                    :FAILED

### D — is the cert load-bearing?
D_REAL_CERT                 :WROTE
D_BOGUS_PROOF_RANDOM32      {:trust_rejected, :awaiting_capability}
D_PROOF_IS_CHECKED          true

### C — revocation          pid 1932970
C_WRITE_BEFORE_REVOCATION   :ok        ← control: the path worked BEFORE
C_REVOCATION_STORED         1
C_WRITE_AFTER_REVOCATION    :REFUSED
C_WRITE_OUTCOMES_DIFFER     true
C_IDENTITY_READABLE_AFTER   true
C_UNDERSTANDING_READABLE_AFTER   readable
C_HISTORY_READABLE_AFTER    ["deployment-a", "deployment-b"]
C_FINDING_READABLE_AFTER    %{"observed" => …, "severity" => "p1"}
C_FINDING_ATTRIBUTABLE_TO   "deployment-a"
```

## §14's acceptance, item by item

| requirement | result |
|---|---|
| A reads an artifact, writes a finding and a yield, exits | ✅ promoted by reference |
| B starts with a fresh context and reconstructs from records | ✅ separate OS process |
| B resolves the yield | ✅ value read from the store |
| B updates understanding | ✅ `fresh/deployment-a` → `resolved/deployment-b` |
| **B has NO context continuity with A** | ✅ **and the control proves it** |
| after revocation, writes freeze | ✅ `:ok` → `:REFUSED`, computed differ |
| identity, findings, history remain readable and attributable | ✅ all four, after revocation |

## ⭐⭐ The control is the thesis, and it is why "B succeeded" means anything

**B's only inputs are key custody, and three ADDRESSES** (the log uuid, the
identity root uuid, the cert id). **All CONTENT comes from the store.**
⇒ **The control runs the SAME script with the SAME custody and the SAME
addresses against a store that never saw A, and it FAILS.**
⇒ ⛔ ***Without it, "B succeeded" could not distinguish READING THE RECORDS from
RE-DERIVING BY DEFAULT.***

## ⚠️ TWO FALSE ALARMS I RAISED AGAINST THE SYSTEM, BOTH MINE

Recorded because the near-misses are the useful part.

1. **"Capability proofs are not checked at all"** — a random 32-byte proof wrote
   successfully. ⇒ **My harness had put the CHILD in `trusted_identities`, so its
   writes were authorized by IDENTITY TRUST and never reached the capability
   path.** `I1`'s own fixture trusts only the issuer. ⭐ *Caught because a
   known-good result (`I1`'s round) contradicted my measurement — read the
   control before believing the alarm.*
2. **"Revocation does not freeze writes"** — same cause. With the child trusted
   outright, revoking its cert could not matter. **After the fix: `:ok` before,
   `:REFUSED` after.**

⭐ **And a third, smaller: the real cert was refused as `:capability_insufficient`
because my probe REPLACED the record and dropped its protected `zone` field.**
`subtree_carve_ok?` refuses exactly that. **The carve was working; the probe was
wrong.** ⇒ *Updates must MERGE onto the current record.*

## ⛔ What this does NOT prove — the bounds of the claim

- **Fixture signing contexts throughout.** No real node identity; `NodeIdentity`
  was never the signer.
- **Key custody is a JSON file** standing in for the child workspace
  `SecretStore`. The real store is CubDB at `<data_dir>/secrets` and would
  survive the same boundary, but that path was NOT exercised here.
- **Both deployments run the same worker identity.** A parent/child *pair* of
  distinct running agents was not demonstrated.
- **No eviction.** That is `I4`'s arm; this run did not exercise the ephemeral
  tier or a tombstone.
- **`I5` ran on the host with a temp store** — never the live store.
- ⚠️ **An instrument error in the capture: `control_rc=0` in `i5_run.txt` is
  MEANINGLESS — the exit code was swallowed by a pipe through `grep` (needed
  `PIPESTATUS`). The control's real verdict is `B_RECORDS_FOUND=0` /
  `B_RESULT=:FAILED`.** *Stated so nobody reads that zero as a pass.*

# BUILD BRIEF — CX-s36k (measurement pass): fill a 2×2 and report it

**For:** Sol (codex)
**Ticket:** **CX-s36k** — ⛔ **MEASUREMENT ONLY. Do not change any behaviour.**
**Worktree:** `/home/jes/sol-s36k2/wt` · **branch:** `sol/cx-s36k-measure`
**Run log:** `/home/jes/sol-s36k2/sol-run.log`

---

## 0. Environment contract (standing)

Named worktree off **current** `origin/main`; ⛔ leave changes **UNSTAGED**, no
`git add`, no commit, no push; ⛔ no serve, no live store — the live store is
`/home/jes/commonplace/workspace/.commonplace/commits/`, **process-derived, NOT
repo-root, NOT `data/`** (stale decoy). **Build fixture stores.**

Suites via `bin/cp-test-guard`, one at a time; ⚠️ **rc from the command itself,
never a pipe**; ⚠️ **a count from a piped listing is not a count**.
⛔ Each `exec` gets a **fresh PID namespace** — redirect long runs to a file and
read the file. ⚠️ **Fresh worktree needs `mix deps.get` first.**

⛔ **NO BARE ZEROS** — any `0` comes with a positive control that the pattern
matches something.
⛔ **EVERY CONTROL THAT WORKS BY REMOVING SOMETHING NEEDS ITS OWN CONTROL** —
if you show behaviour "when X is absent", **prove X was absent.**

## 1. ⛔ THE DELIVERABLE IS A TABLE. THERE IS NO FIX IN THIS TICKET.

`Commonplace.Trust.AuditLog` writes a record for some telemetry events and not
others. **We do not know which variable decides it.** Two candidates are
perfectly correlated in every observation we have, so **no existing data
separates them.**

**Fill this in, by construction, and report it:**

| | **audit-log's own doc** | **some other doc** |
|---|---|---|
| **emitted from an unnamed / foreign process** | ? | ? |
| **emitted from inside the `CommitStore` process** | ? | ? |

**Each cell is: does a record get written — yes or no.**

⇒ ⭐ **That is the entire deliverable.** A four-cell table, each cell backed by
a runnable test, plus the raw output.

## 2. How to build the cells

- `AuditLog.handle_event/4` is the entry point; `attach/2` registers it.
- ⭐ **The record now carries `"firing_process"`** (`%{"registered_name" =>
  …, "pid" => …}`) — added in `73d1e34`. **Use it.**
- **Two doc values:** `AuditLog.log_uuid()` (the audit log's own doc) and any
  other UUID.
- **Two processes:** the test process (unnamed) and the `CommitStore` process
  (fire from inside a store callback).

⛔ **FOR EVERY CELL THAT PRODUCES A RECORD, ASSERT `firing_process` MATCHES THE
PROCESS YOU INTENDED.** ⭐ **Otherwise a filled cell proves nothing** — *"I
fired it from the store"* would be an unchecked claim about your own test
harness, and a cell filled by accident looks exactly like a cell filled on
purpose. **This is why that field was added; it exists to make your
construction checkable.**

⚠️ **For every cell that produces NO record, prove the provocation actually
happened** — that the event was emitted at all, and from where. ⛔ **"No record
appeared" and "nothing fired" must not be indistinguishable in your report.**

## 3. ⛔ Acceptance — artifacts only

1. **The four-cell table**, each cell **yes/no**, with the test that produced
   it named.
2. **Raw output pasted** for each cell.
3. ⭐ **`firing_process` asserted for every record-producing cell**, and its
   value stated.
4. ⭐ **Evidence that the two empty-looking cells (if any) had a real
   provocation** — see §2.
5. `mix compile --warnings-as-errors` rc=0, and:
   - `apps/commonplace/test/commonplace/trust` — **196 tests, 0 failures on
     main**. **Baseline it first and report both numbers.**

## 4. ⛔ OUT OF SCOPE — this is the important part

- ⛔ **DO NOT change `recursion_guard/1`, `handle_event/4`, or any other
  behaviour.** Tests only.
- ⛔ **DO NOT propose, design, or describe a fix.** ⭐ **Do not explain WHY a
  cell is empty. Report THAT it is empty.** The explanation is a separate
  decision that depends on this table, and offering one now would pre-empt it.
- ⛔ **Do not investigate historical incidents, logs, or crashes.** **The table
  is built fresh, from tests you write. Nothing outside this worktree is in
  scope.**
- Any other defect: **note it in one line; do not pursue it.**

## 5. What you cannot verify here

- ⛔ Anything requiring a live serve. **Report UNVERIFIED and stop.**
- This ticket needs **no trust anchor and no signing**. ⭐ **If you find
  yourself wanting one, stop and say so** — the scope has drifted.

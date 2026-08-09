# BUILD BRIEF — CX-8fyq (part 1): record which process emitted the event

**For:** Sol (codex)
**Ticket:** **CX-8fyq** — **part 1 only** (the local, free half)
**Worktree:** `/home/jes/sol-8fyq/wt` · **branch:** `sol/cx-8fyq-firing-process`
**Run log:** `/home/jes/sol-8fyq/sol-run.log` (beside the worktree)

---

## 0. Environment contract (standing)

Named worktree off **current** `origin/main`; ⛔ leave changes **UNSTAGED**, no
`git add`, no commit, no push; ⛔ **no serve, no live store** — the live store
is `/home/jes/commonplace/workspace/.commonplace/commits/`, **process-derived,
NOT repo-root and NOT `data/`** (that path exists and is a stale decoy).
**Build fixture stores.**

Suites via `bin/cp-test-guard`, **one at a time**; ⚠️ **rc from the command
itself, never a pipe**; ⚠️ **a count from a piped listing is not a count**.
⛔ Each `exec` gets a **fresh PID namespace** — redirect long runs to a file
and read the file; never poll `ps`/`pgrep`. ⚠️ **Fresh worktree needs
`mix deps.get` first** (you have network).

⛔ **NO BARE ZEROS.** Any count of `0` you report must come with a **positive
control showing the pattern matches something.** ⭐ *A zero from a pattern you
wrote is a claim about your pattern first.*

⛔ **EVERY CONTROL THAT WORKS BY REMOVING SOMETHING NEEDS ITS OWN CONTROL.** If
you prove behaviour "when X is absent", **also prove X was absent.** ⭐ A
control that never created its condition **returns and looks exactly like a
pass.**

## 1. The gap — a documented concept with no corresponding data

`Commonplace.Trust.AuditLog` records events into a red log. Its moduledoc
(audit_log.ex:41-42) states plainly:

> *"Telemetry handlers run in the process that fired the event.
> `handle_local_write_denial/3` fires from inside `CommitStore.handle_call`."*

⇒ **The module names the emitting process as a concept.** But the record
`build_payload/3` produces (audit_log.ex:268+) carries only:

    event · gate · doc_uuid · commit_id · mode · signer_id_claimed
    check · reason · cert_chain · system_time

⇒ ⛔ **No process, no caller.** ⭐ **The concept is in the prose and absent from
the data**, so anyone reading the module believes it is recorded and anyone
reading the records finds it isn't.

**Measured cost:** four separate investigations have been unable to answer
*"which component emitted this?"* from the corpus, and each had to reconstruct
it by other means or give up.

## 2. Why this is local and cheap — no emission site changes

`handle_event/4` (audit_log.ex:189-191) calls `build_payload/3` **inline**, and
telemetry handlers run **in the emitting process**. ⇒ ⭐ **`self()` inside
`build_payload/3` IS the emitting process.**

⇒ **Add the field there. Do not touch any call site that emits telemetry, and
do not add any new argument to the emit path.**

## 3. ⚠️ A raw pid is not enough — it is meaningless after a restart

⛔ **A pid is per-boot.** `#PID<0.123.0>` from yesterday's boot identifies
nothing today, and the corpus spans boots (records carry `boot_id`).

⇒ **Carry the DURABLE identity where one exists, and say so when it does not:**
- the **registered name** if the process has one
  (`Process.info(self(), :registered_name)`),
- otherwise a stable descriptor if one is cheaply available,
- **and the raw pid as well**, which is still useful *within* a boot.
⭐ **Never emit only the pid.** ⚠️ **And when no durable identity exists, the
field must say that explicitly rather than being absent** — *"unnamed"* and
*"field missing"* must not look alike.

## 4. ⛔ ACCEPTANCE — the field must be shown to DISCRIMINATE

1. **Two provocations from genuinely different processes** produce two records
   whose new field **DIFFERS.**
   ⛔ **A single provocation proves nothing** — a hardcoded constant passes it.
2. ⭐ **POSITIVE CONTROL THAT THE FIELD IS NOT CONSTANT:** state both values.
   ⚠️ If they are equal, that is a **failure**, not a pass.
3. **One of the two must be emitted from inside a `CommitStore` callback** —
   i.e. the store process — and the field must **name the store**, since that
   is the case the four blocked investigations needed.
4. **Existing records still validate**: every other field is unchanged, and
   any existing test asserting on the record shape still passes.
5. **RED-FIRST:** show the field's absence first — a record built today has no
   such key. Paste it.
6. `mix compile --warnings-as-errors` rc=0. Named suites, **baselined on main
   first**, one at a time, both counts:
   - `apps/commonplace/test/commonplace/trust` — **195 tests, 0 failures on
     main**
   - `apps/commonplace/test/commonplace/store` — **5 doctests + 450 tests, 0
     failures on main**

## 5. ⛔ Out of scope — do not widen

- ⛔ **Do NOT add a `principal` / "who requested it" field.** That one needs a
  value propagated across a boundary that does not currently carry it, and
  adding it here would produce a field that is `nil` for two different reasons
  with no way to tell them apart. **Different ticket, different design.**
- Do not change what telemetry any site emits, or add arguments to emit calls.
- Do not change the rate limiter, the dispatcher, or any guard.
- Any other defect: **report it, don't fix it.**

## 6. What you cannot verify here

- ⛔ **Anything requiring the live serve** — it is days behind `main` and this
  code is not deployed there. **Report UNVERIFIED and stop; do not
  approximate.**
- This ticket needs **no trust anchor and no signing**. ⭐ **If you find
  yourself wanting one, stop and say so** — it means the scope has drifted.

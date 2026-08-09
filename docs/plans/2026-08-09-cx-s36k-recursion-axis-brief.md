# BUILD BRIEF — CX-s36k: `recursion_guard/1` guards the wrong axis

**For:** Sol (codex)
**Ticket:** **CX-s36k** (p2/bug)
**Worktree:** `/home/jes/sol-s36k/wt` · **branch:** `sol/cx-s36k`
**Run log:** `/home/jes/sol-s36k/sol-run.log` (beside the worktree)

---

## 0. Environment contract (standing)

Named worktree off **current** `origin/main`; ⛔ leave changes **UNSTAGED**, no
`git add`, no commit, no push; ⛔ **no serve, no live store** — the live store
is `/home/jes/commonplace/workspace/.commonplace/commits/` (**process-derived,
NOT repo-root, and NOT `data/`** — that path exists and is a stale decoy).
**Build fixture stores.**

Suites via `bin/cp-test-guard`, **one at a time**; ⚠️ **rc from the command
itself, never a pipe**; ⚠️ **a count from a piped listing is not a count**;
⚠️ **the default is not the value** — read constants at the **call site**.
⛔ Each `exec` gets a **fresh PID namespace** — redirect long runs to a file
and read the file, never poll `ps`/`pgrep`. ⚠️ **A fresh worktree needs
`mix deps.get` first** (you have network).

### ⛔ TWO REPORTING RULES — they are part of the work

1. ⛔ **EVERY CONTROL THAT WORKS BY REMOVING SOMETHING NEEDS ITS OWN CONTROL.**
   If you prove *"it behaves correctly when X is absent"*, you must **also
   prove X was actually absent.** ⭐ A control that never created its condition
   **returns and proves nothing, and looks exactly like a pass.** *(This
   happened to the author yesterday: hiding a process by restricting `PATH`,
   where the tool was still on the default path — `rc=0` read as "the absent
   case was exercised.")*
2. ⛔ **NO BARE ZEROS.** Any count of `0` you report must arrive with a
   **positive control showing the pattern matches SOMETHING.** ⭐ Three greps
   this week returned `0` on correct code — a guard clause instead of a literal
   tuple, `doc_uuid:` instead of `doc_uuid=`, a namespace that logs under
   another name. **A zero from a pattern you wrote is a claim about your
   pattern first.**

## 1. The defect

`Commonplace.Trust.AuditLog.recursion_guard/1` (audit_log.ex:247-248):

```elixir
def recursion_guard(%{"doc_uuid" => doc_uuid}), do: doc_uuid == log_uuid()
def recursion_guard(_), do: false
```

⇒ **A pure function of the PAYLOAD**: *"does this event name the audit log's
own doc?"*

⛔ **But the recursion it exists to prevent is BY PROCESS.** Telemetry handlers
run **in the process that fired the event**. The loudest denial fires from
inside `CommitStore`'s `handle_call`. ⇒ **A handler that calls back into
`CommitStore` is `:calling_self` — whatever doc the event names.**

⭐ **The guard closes a real loop** (a denial *of the audit doc* would enqueue
another audit write) — **and it is a different loop from the one that can
actually fire.** Having closed the visible one is why nobody looked for the
other.

⚠️ **AND `:telemetry` ANSWERS AN UNCAUGHT EXIT BY PERMANENTLY DETACHING THE
HANDLER.** So a re-entry does not merely fail — **it takes denial auditing off
the air until something re-attaches.**

## 2. ⛔ WHAT THE HISTORICAL EVIDENCE IS, AND WHAT IT IS NOT

`workspace/.commonplace/serve.log` (a **2026-08-05-build** process) contains
**nine**:

```
[error] Handler "commonplace-trust-audit-log" has failed and has been detached.
Class=:exit Reason={:calling_self, {GenServer, :call,
  [Commonplace.Store.CommitStore, {:put_built_commit, %Commit{doc_uuid: "f4e8eac8-…"
```

⛔ **DO NOT TRY TO REPRODUCE THAT CRASH.** It is from an **older build**, and
`main` has since moved — the dispatcher now drains through
`Task.Supervisor.async_nolink` (audit_dispatcher.ex:480), **off the caller's
process**, so the specific path that produced those nine may no longer exist.
⚠️ **Chasing it would be chasing a ghost, and "I could not reproduce it" would
be a true and useless result.**

⇒ ⭐ **RED-FIRST MEANS: CONSTRUCT THE RE-ENTRY DIRECTLY.** Fire the denial
telemetry **from inside a `CommitStore` callback** (or otherwise from the store
process) with a handler that does store work, and show `:calling_self` — **and
show the guard does not prevent it, because the payload names a different
doc.** **That is the defect, and it is provable on `main` regardless of what
the old build did.**

## 3. The fix

Guard on the axis the hazard lives on: **is this process already inside the
audit-write path / is it the store process we would call back into.** A
process-dictionary flag, or a structural rule that the handler never calls the
store synchronously.

⛔ **KEEP the doc-keyed guard — it closes a real loop. ADD the process axis. Do
not swap one for the other.**

⚠️ **And reconcile the comment**: `application.ex:49-56` asserts the handler
"deliberately does NO store work". ⭐ **If that is now true on `main`, say so
with the evidence and make the guard defensive rather than corrective** — a
guard whose hazard is currently unreachable is still worth having if the
comment is the only thing holding the property.

## 4. ⛔ Acceptance — artifacts, not assurances

1. ⭐ **RED:** the constructed re-entry from §2, pasted, showing `:calling_self`
   (or the handler exiting) **with the doc-keyed guard in place and not
   preventing it.**
2. **GREEN:** the same provocation with the process-axis guard, **and — the
   consequence that actually matters — ⛔ ASSERT THE HANDLER IS STILL
   ATTACHED AFTERWARDS** (`AuditLog.attached?/0`). ⚠️ *"No exception was
   raised"* does not imply it. **Detachment is the damage.**
3. **The doc-keyed loop still cut:** a denial naming the audit doc still takes
   the `recursion_guard` branch. ⛔ Do not regress it while adding the axis.
4. ⛔ **CONTROL-FOR-THE-CONTROL (§0 rule 1):** if any test proves behaviour
   "when the handler is detached" or "when X is absent", **prove the
   precondition held** — e.g. assert `attached?/0` is `false` before the
   assertion that depends on it.
5. `mix compile --warnings-as-errors` rc=0. Named suites, **baselined on main
   first**, one at a time, both counts:
   - `apps/commonplace/test/commonplace/trust` — **195 tests, 0 failures on
     main**
   - `apps/commonplace/test/commonplace/store` — **5 doctests + 450 tests, 0
     failures on main**

## 5. ⚠️ What you cannot verify in-sandbox — report UNVERIFIED and stop

- ⛔ **Anything requiring the live serve.** It is 4 days behind `main` and this
  code is not deployed there. **Do not attempt a live check.**
- ⛔ **Whether the nine historical crashes recur.** That needs the old build.
  **Not your criterion; do not approximate it.**
- The fence's red-is-expected property for node-signed writes is in the runner
  header — **this ticket should not need a real anchor at all.** If you find
  yourself wanting one, **say so and stop.**

## 6. Out of scope

- The capture-rate instrument (CX-m0qw), canary exclusion (CX-7kx7), denial
  attribution (CX-8fyq). **Report anything you notice; fix nothing.**
- Any change to what telemetry the store emits.

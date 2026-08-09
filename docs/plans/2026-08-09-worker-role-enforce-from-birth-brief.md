# BUILD BRIEF — enforce-from-birth: a declared worker role refuses to start permissive

**For:** Sol (codex) · **plan's #2** (releases the worker lane)
**Worktree:** `/home/jes/sol-birth/wt` · **branch:** `sol/enforce-from-birth`
**Run log:** `/home/jes/sol-birth/sol-run.log`

---

## 0. Environment contract (standing)

Named worktree off **current** `origin/main`; ⛔ leave changes **UNSTAGED**, no
`git add`, no commit, no push; ⛔ **no serve, no live store** — the live store is
`/home/jes/commonplace/workspace/.commonplace/commits/`, **process-derived, NOT
repo-root and NOT `data/`**. ⚠️ **`mix deps.get` first.**

⚠️ **rc from the command itself, never through a pipe.** ⛔ **NO BARE ZEROS** —
any `0` arrives with a positive control that the pattern matches something.

## 1. The defect

`Trust.default_config/0` (`trust.ex:1190`) returns
`%{accept_unsigned: true, trusted_identities: %{}}`.

⇒ **A node whose `trust.json` is never written comes up PERMISSIVE, with every
gate on it decorative.** For a single-operator dev clone that is the intended
zero-config default. **For a sandboxed autonomous worker it means the gates are
theatre**, and nothing says so at the one moment it matters.

⭐ **The chokepoint already exists and already detects this condition — it just
warns.** `Commonplace.Process.Orchestrator.warn_if_permissive/0`
(`process/orchestrator.ex:185-195`) reads `Trust.config()` at orchestrator
start and logs when `accept_unsigned` is true.

⇒ **The gap is warn-vs-refuse for ONE declared role. It is not "build a
runner."**

## 2. ⛔ The four clauses — these are plan's ruling, not suggestions

**① THE MARKER IS A POSITIVE, EXPLICIT DECLARATION.**
A config/env node role (`role = worker`). ⛔ **NEVER inferred from hostname,
sandbox detection, environment sniffing, or the presence/absence of any file.**
⭐ *Inference is the fence-fact class; never-rely-on-absence applies.* A node is
a worker because someone SAID so.

**② ABSENT MARKER = TODAY'S BEHAVIOUR, WITH THE WARN PRESERVED.**
⛔ **Adding a refusal for one role must not drop the warning for everyone else.**
⚠️ It would be very easy to restructure this function and lose the warn on the
unmarked path — **that is a silent regression of an existing safety surface.**

**③ MARKED + PERMISSIVE = A NAMED REFUSAL STATING BOTH FACTS AND THE DOOR.**
Shape: *"role=worker declared and trust config permissive — write trust.json or
remove the role."* ⭐ **Both facts, and the sanctioned action.** ⛔ Not a bare
raise, not a generic message.

**④ RED-FIRST IS WRITABLE TODAY**, because marked+permissive currently
warns-and-starts.

## 3. ⛔ Acceptance — artifacts

1. ⭐ **RED-FIRST:** marked + permissive on unmodified `main` — show it **starts
   and only warns.** Paste it. ⛔ Prove the marker was set, or the red shows
   nothing.
2. **After: marked + permissive REFUSES**, with the message naming both facts.
   Paste the actual message.
3. ⭐ **CONTROL — marked + explicit config STARTS.** A refusal that fires on the
   good case is worse than none.
4. ⭐⭐ **CONTROL — UNMARKED + permissive STARTS, AND THE WARN IS STILL EMITTED.**
   ⛔ **Assert the warning is present, not merely that boot succeeded.** ⚠️ This
   is clause ②, and it is the one a passing suite hides: dropping the warn
   breaks nothing and shows up as green.
5. ⛔ **No inference:** show that setting *only* a sandbox-ish environment
   (without the explicit marker) does **NOT** trigger the refusal.
6. `mix compile --warnings-as-errors` rc=0.

## 4. ⛔ SUITES — NAMED BY BLAST RADIUS

⚠️ This adds a **refusal at orchestrator start**, and the orchestrator boots
with the application — so the blast radius is *every app that boots it*, not the
file you are editing. **This exact mistake cost three reverts today.**

**Baseline each FIRST, report both numbers, one at a time:**

- `apps/commonplace/test/commonplace/process` — **66 tests, 0 failures on main**
- `apps/commonplace/test/commonplace/trust` — **213 tests, 0 failures on main**
- `apps/commonplace_web/test` — **12 features, 134 tests, 0 failures, 12 excluded**
- `apps/commonplace_mcp/test` — **156 tests, 0 failures on main**
- `apps/commonplace_cli/test` — **97 tests, 0 failures on main**

⭐ *(Measured on main at `11946eb`. Older briefs quoting 195/196/197/201/206/210
for trust are stale.)*

⚠️ `CommitHoistTest` (CX-qzbh) is load-marginal; `BotPresenceCertTest` times out
in the FULL mud suite on main. One line each if seen; move on.

## 5. ⛔ Out of scope

- ⛔ **Do NOT change `Trust.default_config/0`.** Flipping the zero-config default
  substrate-wide is a separate, owned decision (merged with CX-1ern) and is
  explicitly NOT to be done as a side effect of this ticket.
- ⛔ Do not write a provisioning script or a worker runner. **They do not exist
  and are a separately-sized item.** ⭐ This ticket makes enforcement precede the
  runner, so the runner is later born into an already-refusing world and merely
  sets the marker.
- ⛔ Do not touch `prior_world_evidence?/1`, the mint path, or the public-key
  artifact work.
- Any other defect: **one line, don't pursue it.**

## 6. What you cannot verify in-sandbox

- ⛔ Anything requiring the live serve — report **UNVERIFIED** and stop.
- ⭐ **Everything in §3 is reachable from app env + a fixture data_dir.** If you
  find yourself needing the live workspace, the scope has drifted — say so and
  stop.

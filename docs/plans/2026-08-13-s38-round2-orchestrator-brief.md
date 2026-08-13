# S38 round 2 build brief: the orchestrator half — CX-7men

> **The work's ticket is CX-7men** (still open; round 1 landed the schema
> at `f7108e34`). ⭐ **Plan's acceptance criterion, ruled 2026-08-13 and
> quoted because it is better than any restatement: the `+` in
> "instance-declaration schema + orchestrator recipe-profile" is
> CONJUNCTIVE, not a menu — "the schema is the contract, the orchestrator
> half is what makes it load-bearing, and A RECIPE FORMAT NOTHING
> CONSUMES IS A DOCUMENT, NOT A CAPABILITY."**
>
> ⇒ ⭐⭐ **THE ROW SATISFIES WHEN A RECIPE BOOTS SOMETHING.** That is an
> **EFFECT, not an artifact**: not *the schema exists*, not *the tests
> pass*, but **something ran because of it.** Same family as *test the
> capability, never the handle*, one level up — **a format is verified by
> a consumer exactly as a fence is verified by an attempt.**

## What to build

Wire the landed `Runner.RunRecipe` to the landed `Runner.Launcher`, so a
recipe is what causes a process to run in a pod. **Every piece this
consumes already exists — consume them, do not reimplement:**

| recipe field | where it goes |
|---|---|
| `run` | becomes the pod's **invocation** (`Launcher.launch/…`'s `invocation:`) |
| `env` (NAMES) | resolved against the pod's **explicitly constructed environment allowlist** (`provisioner.ex` builds it from empty) — the recipe declares what it needs, the placement supplies values |
| `requires` | gates the placement via **`PodProfile.match_requires/2`** — satisfy or refuse, service named |
| `setup` | runs before `run` (see the open question below) |
| `port`, `ready` | ⚠️ **readiness polling is very likely a later rung** — see scope |

## ⛔ Scope, and where I expect it to stop

- ⛔ **`env` VALUES never come from the repo or the substrate.** The
  recipe names; the placement supplies. A recipe carrying a value is
  already a refusal in round 1 — **do not add a path that lets one
  through.**
- ⚠️ **`ready`/`port` polling turns this into a readiness service.** If
  booting cleanly needs only `run`, **land that and report `ready` as
  unconsumed** rather than growing the round. **One unknown per rung.**
- ⛔ **No new subsystem.** S39's falsifier still binds and is now
  enforced by a test for the schema's shape; the same spirit applies
  here — **if this needs a new module beyond wiring, STOP AND REPORT.**
- ⛔ **No live-store or serve contact.** Fixture pods only.

## ⭐ Acceptance is an EFFECT, and it must be observed

**A fixture recipe boots a fixture process in a real pod, asserted by
effect** — the same shape as the launcher's existing tests, which assert
a file the worker wrote rather than the absence of an error.

- ⭐ **The effect must be caused BY THE RECIPE**, not by a hard-coded
  invocation that happens to match it. **Change the recipe's `run` and
  the observed effect must change** — otherwise the test proves the
  launcher works, which was already known.
- **`requires` gates for real**: a recipe whose requirement the profile
  cannot satisfy **refuses, with the service named**, and no pod is
  launched. Both directions observed.
- **The test LANDS as a file AND its own count is reported.** ⚠️ *A test
  must EXIST and EXECUTE — each half alone is enough to make a review
  pass, and this arc produced one of each.*

## ⛔ Standing brief discipline (this arc's, all earned)

- ⛔ **Never a commit** — `.git` is read-only. Produce the **intended
  commit message**.
- ⛔ **Do not run `mix format` or `mix precommit`** — they reformat
  repo-wide as a side effect. Use `mix format --check-formatted`.
- **Measure your own baseline; do not trust the one below.** A stale
  baseline is a number that WAS right, so it survives every plausibility
  check. (Last known: full core **3,464 / 0 / 1 skipped** @f7108e34.)
- **Name the files you may touch**; anything else stays byte-identical.
- ⛔ **If you cannot find this brief, STOP AND SAY SO** rather than
  reconstructing the task from the prompt.
- ⛔ **If a fenced capability is needed, NAME IT** rather than working
  around its absence. The sandbox has no `~/.ssh`, an allowlisted env,
  masked channels, and an isolated PID namespace — **a `0` result from a
  probe may mean MASKED, not ABSENT.**
- ⭐ **Report the NEAR-MISS**: anything that tempted you toward a new
  module, a seventh recipe field, or reading a value from the repo —
  **stated even if you did not act on it.** *The fence approached and
  held is different information from the fence never approached* — and
  in round 1 this produced the arc's best artifact.

## Open question to answer, not to assume

**Where does `setup` run, and when?** It is the app's own commands
(installs, migrations) and must precede `run`. ⚠️ **Whether that is one
pod invocation with two phases, or two, is a design decision — state
which you chose and why**, and if it forces a new abstraction, that is
the STOP-AND-REPORT case.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). ⚠️ Not
reachable from inside the sandbox — a capability boundary, not a defect.
Report identities; the reviewer files them.

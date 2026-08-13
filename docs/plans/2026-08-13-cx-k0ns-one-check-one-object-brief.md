# CX-k0ns build brief: one check against one object

> **The work's ticket is CX-k0ns** (open, p2, filed 2026-08-13 during
> S48's review). Branch base: **`7cf3aa4c`** on `main`.
>
> ⛔⛔ **THE ROUND'S STOP CONDITION, PLAN'S RULING, READ IT FIRST: DO NOT
> CLOSE THIS ON THE MITIGATION'S STRENGTH.** A `Map.fetch!` already
> landed that makes the divergence **loud**. ⚠️ **A loud divergence is
> not a removed one.** If your work ends with "the mitigation covers
> it," you have not done this round — **stop and report that instead.**
>
> ⭐ Plan's general form, worth carrying: **"the better a mitigation
> performs, the more it looks like a fix, and the quieter the residual
> gets."** ⇒ The relationship is **inverse** — a mitigation's *success*
> is exactly what removes the evidence that something is still wrong.

## The defect, precisely

`Launcher.launch_recipe/5` (`apps/commonplace/lib/commonplace/runner/launcher.ex`)
validates a recipe's declared `env` **names** against one object and then
resolves them against **a different one**:

| step | object |
|---|---|
| availability check (`environment_available?/2`) | `Provisioner.sandbox_spec(profile, state.pods_root)` — ⚠️ **the pods ROOT: a STAND-IN for a pod that does not exist yet** |
| resolve (`resolve_environment/2`) | `pod.sandbox_spec.environment` — **the REAL provisioned pod** |

⭐ **It is correct today only because the environment key set is a fixed
literal independent of `pod_home`** (`provisioner.ex:76` builds
`COMMONPLACE_DATA_DIR`, `HOME`, `LANG`, `LC_ALL`, `PATH` from empty; only
the **values** vary with the pod). **That invariant is load-bearing,
and until CX-k0ns it was unstated and untested.**

⚠️ **A validation that runs against a stand-in proves a property of the
stand-in.** ⇒ The general question, which is the reusable part: **what
object did the check run against, and what object does the code then
use?**

## ⭐ How it was found, because it constrains what counts as fixed

The resolve was `Map.take(environment, names)`. **`Map.take` cannot
fail** — so a declared variable whose key was missing would go
**silently absent** from the pod, and the pod would **boot without it**.

⭐⭐ **That is a check that cannot fail wearing a data operation's
clothes — nothing at the call site looks like a check at all**, which is
why a review hunting that exact class all day walked past it.
⇒ **Search for the OBLIGATION — *where must this reject?* — not for
syntax shaped like an assertion.**

## What to build

**One source of truth for the pod environment's KEY SET, consumed by
both sites**, so the check and the use name the same object.

⭐ **The module already states this principle about itself, and the fix
should follow it rather than invent a new pattern** —
`sandbox_spec/2`'s own moduledoc:

> *"There is intentionally no masks argument. The credential floor is
> part of construction, not a convention a caller must remember."*

⇒ **The environment key set is the same kind of thing.** A caller that
reconstructs a throwaway spec against a fake `pod_home` in order to
learn the key set **is remembering a convention** — exactly what that
sentence refuses for masks.

- ⭐ **The key set is a property of the POD CONTRACT, not of a
  particular pod.** Name it once (a function on `Provisioner`), have
  `sandbox_spec/2` **build from it**, and have the launcher **check
  against it**. ⛔ **Not two literals kept in agreement** — that is the
  same defect with better manners.
- ⛔ **The graceful refusal MUST STAY BEFORE PROVISIONING.** That is
  what makes the landed tests' `pod_homes == []` assertion possible:
  **refusal means NO POD, observed.** Moving the check after
  provisioning would mint a pod only to tear it down, buying new
  cleanup semantics for nothing.
- **State what happens to the `Map.fetch!` and why.** Once both sites
  consume one object it may be total by construction — that is a
  legitimate outcome, **but say which it is** rather than leaving it as
  scenery. ⚠️ If you keep it, say what could still make it raise; if you
  remove it, say what now makes that safe.

## ⭐ Acceptance: a test that FAILS if the key set ever becomes pod-dependent

The point is not that the two agree today — they do. **The point is
that a future divergence is caught.**

- ⭐⭐ **The load-bearing invariant becomes an executable assertion**:
  the names the launcher checks against are **the same names an actually
  provisioned pod's environment has**. Assert it against **a real
  provisioned pod**, not against a second stand-in — *a test that
  compares two stand-ins proves a property of stand-ins.*
- ⭐ **Demonstrate it can go RED, by your own revert-control**:
  temporarily make the key set pod-dependent (an extra key derived from
  `pod_home`), show the new test fails, revert, show it passes.
  **Report both outcomes.** ⚠️ *A gate never seen fail is not known to
  work* — and this one is guarding an invariant that currently cannot
  be violated, which is precisely when a vacuous test is undetectable.
- **The landed recipe arms must still pass unchanged** — both refusal
  directions still refuse before provisioning, `pod_homes == []` still
  holds, and the two-recipe causation arm is untouched.
- **Tests LAND AS FILES and each file's own count is reported from the
  tree** (`mix test <path>` → *N tests, 0 failures*).

## Files

- **MAY touch**: `apps/commonplace/lib/commonplace/runner/launcher.ex` ·
  `apps/commonplace/lib/commonplace/runner/provisioner.ex` ·
  `apps/commonplace/test/commonplace/runner/launcher_recipe_test.exs` ·
  provisioner tests · one new test file if the property wants its own home.
- ⛔ **MUST NOT change, pinned by md5** —
  `run_recipe.ex` = `230839fc23e1047282306486ea48db41`,
  `run_recipe_test.exs` = `07c92ded3ac4668225fdff5eb3482602`.
  **Six fields, no seventh; this round does not touch the schema.**
- ⛔ **`sol-egress-run.sh` is never edited from inside a round.**

## Tests

Baseline claim, **falsifiable — measure your own and report it if it
differs**: full core **3,467 / 0 failures / 1 skipped** @`7cf3aa4c`.
⚠️ **Run per-app** — multi-app `mix test` paths silently drop tests here.
⚠️ A worktree cannot host a suite run (no `deps/`, no `_build/`); compile
through writable copies as usual and **report where you ran**.

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only by design. Produce the
  **intended commit message**; the reviewer lands it.
- ⛔ **Do not run `mix format` or `mix precommit`** (they reformat
  repo-wide). Use `mix format --check-formatted`.
- ⛔ **If you cannot find this brief, STOP AND SAY SO** rather than
  reconstructing the task from the prompt.
- ⛔ **If a fenced capability is needed, NAME IT** rather than working
  around its absence. The sandbox has no `~/.ssh`, an allowlisted env,
  masked channels, an isolated PID namespace — **a `0` from a probe may
  mean MASKED, not ABSENT.**
- ⭐ **Report the NEAR-MISS** — anything that tempted you toward the
  schema, a second literal, or moving the refusal after provisioning,
  **stated even if you did not act on it.**
- **Report a MEASUREMENT, never a mechanism you did not observe.**

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). ⚠️ Not
reachable from inside the sandbox — **a capability boundary, not a
defect.** Report identities; the reviewer files them.

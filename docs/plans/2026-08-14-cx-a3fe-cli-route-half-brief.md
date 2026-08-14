# CX-a3fe build brief: find out WHY the CLI never routes — measured, not reasoned

> **The work's ticket is CX-a3fe.** Base: **the commit that adds this brief**
> — ⚠️ *deliberately not a sha: a brief that names its own base is stale the
> moment it is committed, because committing it moves HEAD past the sha it
> just recorded.* Verify with `git ls-remote origin main` before cutting.
>
> ⭐ **The defect is not that the CLI refuses. Refusing is CORRECT and it is
> what prevented the 2026-08-06 live-store corruption from being possible
> again.** ⛔ **The defect is that it ALWAYS refuses, so the ROUTING BRANCH IS
> UNTESTED IN PRACTICE** — and *a disjunctive acceptance ("route OR refuse")
> is satisfied by whichever branch fires, which means it CANNOT DETECT THE
> OTHER BRANCH DYING.*

## The observation, measured on the live box

`commonplace_cli bd ready`, run from the workspace dir **with the serve up**,
`rc=1`:

```
commonplace: refusing to open the commits store …
  It is LOCKED by another live process (flock on …/commits.lock), and no
  running `commonplace serve` for this workspace could be reached…
  Holder hint (NOT proof …): 347040 commonplace_dev@commonplace
Nothing was opened and nothing on disk was touched. (CX-x8jk)
```

⇒ **A serve WAS running and the CLI could not reach it.** ⭐ **Nothing was
opened — the safe branch worked.**

## ⛔ A candidate I found by reading AND THEN REFUTED — do not inherit it

⚠️ **I first believed the cause was `access.ex:224`:**
`Node.connect/1` returns `:ignored` when the calling node is not alive, and
the check is `== true`. **An escript that is not a distributed node would
always fall through to refuse.**

⛔ **THAT IS WRONG, and reading twenty lines further shows why:
`connect_to_serve/1` CALLS `Node.start(cli_name, :shortnames)` FIRST.** The
CLI *does* make itself distributed. ⇒ **The `:ignored` branch is defensive,
not the live path.**

⭐ **I am carrying this refuted candidate deliberately, for two reasons:** so
you don't rediscover it and spend the round there — and because **it is what a
plausible-looking mechanism costs when it is written into a brief as fact.**
⚠️ *A candidate that reads as obvious is the one most likely to be stated as
the answer.*

## The actual question — and it is a MEASUREMENT, not an explanation

**WHICH STEP OF `Commonplace.CLI.Access.connect_to_serve/1` FAILS, OBSERVED?**

```elixir
read_node_name(data_dir)          # nil            → :not_running
Node.start(cli_name, :shortnames) # {:error, _}    → :not_running   ← epmd? already distributed?
Node.connect(serve_node)          # false/:ignored → :not_running   ← cookie? name resolution?
verify_serves_this_dir(...)       # {:mismatch, _} → :not_running   (prints a DIFFERENT message)
```

⭐ **All four collapse to the same outcome and the same user-visible
sentence.** ⇒ ⛔ **That is the ticket's real defect one layer down: FOUR
DISTINCT CAUSES SHARE ONE OBSERVABLE.** *"blocked" and "not there" share an
exit code — here, four of them share a message.*

⚠️ **STRONGEST REMAINING CANDIDATE, offered as a lead and NOT as the answer:
distribution environment.** Every erpc script in this repo must set
`ERL_INETRC=bin/erl_inetrc` and `ERL_EPMD_ADDRESS=127.0.0.1` to reach
`commonplace_dev@commonplace`. **If the escript sets neither, `Node.start` or
`Node.connect` fails for an environmental reason that has nothing to do with
the serve's health.** ⛔ **CONFIRM OR CONTRADICT IT. Do not assume it.**

## ⭐ Acceptance

1. ⭐⭐ **THE FAILING STEP IS NAMED AND OBSERVED — not inferred.** ⇒ **Report
   the actual return value of the step that fails** (`{:error, reason}` from
   `Node.start`, or `false`/`:ignored` from `Node.connect`, or the
   `read_node_name` nil). **Verbatim.**
2. ⭐ **DISTINGUISH THE FOUR CAUSES IN THE OUTPUT.** ⇒ **A user who hits this
   must be able to tell WHICH ONE happened.** *Today all four print the same
   sentence; that is why nobody has diagnosed it in the eight days since
   `CX-x8jk` landed.*
3. ⛔ **DO NOT WEAKEN THE REFUSAL.** ⚠️ *The cheapest way to make a disjunction
   look healthy is to disable the branch that is winning.* **The refusal is
   what makes the store safe; only its indistinguishability is the defect.**
4. **A test that exercises the reach path in a FIXTURE** — start a node vs
   not, and assert the step-level outcomes differ. ⭐ **Red-first: show the
   current code producing the same `:not_running` for two DIFFERENT causes.**
5. ⚠️ **IF FIXING THE REACH ITSELF IS OUT OF SCOPE, SAY SO AND STOP.**
   ⭐ **Naming the step is the deliverable; making routing work may be a
   larger change and is a separate decision.**

## ⛔ What you cannot do, and must not route around

**You cannot reach the live serve from the sandbox** — your own PID namespace
hides it, and the distribution environment is not present. ⇒ ⭐ **Everything
above is answerable in a FIXTURE: start your own named node, point a
`node_name` file at it, and drive `connect_to_serve/1` against it.**
⛔ **Report any live-only step as UNVERIFIED and stop there.** *The reviewer
measures those outside.*

## Files

- **MAY touch**: `apps/commonplace_cli/lib/commonplace/cli/access.ex` ·
  `apps/commonplace/lib/commonplace/store/lock_refusal.ex` (the message) ·
  their tests.
- ⛔ **MUST NOT change**: `runner/run_recipe.ex`
  (md5 `230839fc23e1047282306486ea48db41`) · `runner/run_recipe_test.exs`
  (md5 `07c92ded3ac4668225fdff5eb3482602`) · `bin/cp-deploy-gap` ·
  `test/commonplace/deploy_gap_test.exs` · `bd/schemas.ex`.
- ⛔ **`sol-egress-run.sh` is never edited from inside a round.**

## Suites

Baseline, **falsifiable — measure your own and report it**: core
**3,494 / 0 failures / 1 skipped** at **seed 117514**. ⚠️ **`commonplace_cli`
has its own suite — measure and report that baseline too; it was 118/0 two
days ago and I am NOT carrying that number forward as current.**
⛔ **REPORT THE SEED OF EVERY RUN.** ⛔ **Never pipe a long `mix test`.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact.**
- ⛔ **Do not run `mix format` or `mix precommit`.**
- ⛔ **If you cannot find this brief, STOP AND SAY SO.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION — and it already contains
  one candidate I refuted myself.** ⛔ **If the line numbers, the call chain,
  or the environment lead do not match the artifact, REPORT THE
  DISCREPANCY.** ⚠️ *Eight brief-facts were wrong this week; every one was
  caught by the builder.*
- ⭐ **Report a MEASUREMENT, never a mechanism you did not observe.**
- ⭐ **Report the NEAR-MISS**, especially any temptation to make routing
  "work" by relaxing what counts as reachable.

## Review criteria

The failing step named with its observed return value; the four causes
distinguishable in the output; the refusal not weakened; a fixture test that
is red-first on the shared-observable defect; live-only steps reported
UNVERIFIED rather than simulated; both suites' seeds and self-measured
baselines reported.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). ⚠️ Not reachable
from inside the sandbox — **a capability boundary, not a defect.**

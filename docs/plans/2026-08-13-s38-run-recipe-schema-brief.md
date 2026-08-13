# S38 round 1 build brief: the run-recipe schema — CX-7men

> **The work's ticket is CX-7men.** Design source: commonplace-plan
> `docs/notes/2026-08-12-dev-environments-answer.md` **§6b**. Its stated
> precondition — *"buildable once S32's pods exist to place instances
> in"* — is now met: pods provision **and execute**. jes cleared the
> dev-env gate (*"yes we can start trying to build towards that doc"*)
> ⚠️ **as a green light on the DIRECTION, not clause-by-clause
> ratification: any step that hits a doc-marked-open decision is a FRESH
> ASK naming its question, never a backward reading of the general yes.**

## The design, in one sentence

**The app carries its own answer for running itself; the substrate
carries only the contract for invoking it.** The recipe is a small
declared file **in the repo, versioned with the code, at the pin** — so
a pin that cannot run carries its own evidence, and app/platform drift
is impossible by construction. We adopt that insight and **none of the
tooling** it usually arrives with.

## What to build: a schema for SIX fields and nothing else

| field | meaning |
|---|---|
| `setup` | the app's own commands (installs, migrations, multi-DB prep) |
| `run` | the entry point |
| `port` | the port it serves on |
| `env` | ⛔ **NAMES ONLY, never values** |
| `ready` | a readiness check path |
| `requires` | versioned service names, e.g. `{postgres: ">=14"}` |

⭐ **THIS ROUND IS THE MISSING MIDDLE, AND BOTH ENDS ALREADY EXIST —
consume them, do not reimplement them:**
- **`requires` feeds `Runner.PodProfile.match_requires/2`** (landed):
  closed-by-default satisfy-or-refuse over a version grammar, refusing
  with the service named.
- **`env` names feed the pod's constructed environment allowlist**
  (landed): `provisioner.ex` builds the pod env **from empty**, never
  inheriting. The recipe declares *what it needs*; the placement supplies
  *values*. ⛔ **Values never come from the repo or the substrate** —
  that is the secrets discipline, and a recipe carrying a value is a
  refusal, field named.

Follow **`Cell.Manifest`'s idiom** (landed, and the closest sibling):
validate with `{:invalid_recipe, field, reason}`-shaped refusals naming
the field; a `read/1` that distinguishes *absent* from *present*; and
**refuse-and-name for every field it cannot satisfy.**

## ⭐ Where `requires` came from, because it constrains how you treat it

It was **found by measurement, not design**. A read-only survey of a real
Rails app found the contract's missing field on the first real case:
migrations and multi-database setup are the app's business inside
`setup`, but **a RUNNING postgres cannot come from `setup`, and
provisioning one is where devops starts — so the substrate doesn't.** It
**matches requirements to placements and refuses, loudly**; it never
provisions, migrates, or manages a service.

⇒ Treat `requires` as a **declaration to be satisfied or refused**, never
as a request to be fulfilled. Closed-by-default: **declare,
satisfy-or-refuse, never infer.**

## ⛔ The fence, and it is also the falsifier

S39 states it: **"a second file or a new subsystem = the fence breached
and the design wrong."**

⇒ **Six fields, one file, no companion, no new subsystem.** ⛔ **If the
schema seems to need a seventh field or a second file, STOP AND REPORT
— that is the design being wrong, not the round being small.** Do not
widen it to make a case fit; the widening IS the finding.

- ⛔ **No orchestration, no process spawning, no readiness polling.**
  This round is the *declaration format* and its validation. Invoking it
  is a later rung.
- ⛔ **No live-store or serve contact**; no pods launched.
- ⚠️ **Do not run `mix format` or `mix precommit`** — they reformat
  repo-wide as a side effect. If you need a formatting check, use
  `mix format --check-formatted`.
- If a decision the design doc marks OPEN blocks you, **stop and name the
  question** — it is a fresh ask, not something to resolve locally.

## ⛔ AMENDED 2026-08-13 — the tests must LAND AS A FILE

The first attempt satisfied this brief as written and its tests did not
persist: the arms were exercised in a throwaway harness, reported
honestly with counts, and **no test file entered the tree.** ⚠️ **That is
the brief's ambiguity, not the builder's error** — *"exercise these"* and
*"land these"* are different instructions, and a Tests section listing
arms reads as the first if you are looking for the smallest satisfying
action.

⭐⭐ **AND IT IS THE EXACT MIRROR OF THIS WEEK'S CENTRAL FINDING, which
is why the requirement is now explicit:**

| | review artifact |
|---|---|
| a test that **EXISTS** and has never **EXECUTED** (four rounds, earlier) | *"the property was verified"* |
| a test that **EXECUTED** and does not **EXIST** (this round) | *"the property was verified"* |

⇒ **Both produce the same artifact from opposite causes.** In the first,
the file is there so reading the diff passes it. In the second, the run
happened so reading the report passes it. ⛔ **Neither is a test.**

⭐ **A test must EXIST *and* EXECUTE. Each half can be present without
the other, and each half alone is enough to make a review pass.**

⇒ **SO: the arms below must land as
`apps/commonplace/test/commonplace/runner/run_recipe_test.exs`, and the
round must report THAT FILE'S OWN COUNT** (`mix test <path>` → *N tests,
0 failures*). A count from a harness that is not in the tree does not
satisfy this.

## ⭐ Stated decision: the recipe's PATH is caller knowledge, not schema data

The first attempt reported a temptation it did not act on — *"the
unspecified canonical recipe pathname could have tempted a `path` field;
it remains an argument to `read/1`."* **That was the right call and it
is now a ruling rather than a builder's judgement:**

⇒ **`path` is NOT a seventh field.** A path in the schema would make the
recipe describe its own location — **the one fact the repo already
encodes by containing it.** The location is the caller's knowledge and
stays an argument to `read/1`.
⚠️ **Hatch:** if implementing this reveals a case where the recipe
genuinely cannot be read without self-describing its location, **STOP
AND REPORT** — that would be a real design finding, and it is the same
tension the first round felt.

⛔ **`run_recipe.ex` MUST NOT CHANGE.** It is correct as landed — six
fields, one file, no companion. **This round adds exactly one file.**

## Tests (red-first; suites named with counts)

Baseline: full core **3,458 / 0 failures / 1 skipped** @697a7a8c.
⚠️ Run per-app — multi-app `mix test` paths silently drop tests here.

- **Happy path**: a complete six-field recipe validates, and each field
  round-trips.
- ⭐ **Refusal arms, each field named**: a value in `env` (not a name) ·
  an unparseable `requires` version · a missing required field · an
  unknown seventh field. **Each refusal states which field.**
- ⭐ **The seam that makes this round worth doing**: a recipe's
  `requires` handed to `PodProfile.match_requires/2` **satisfies against
  a profile that carries the service and refuses against one that does
  not, naming the service.** Observe both directions — a matcher that
  only ever satisfies proves nothing.
- Prove any "pre-existing/unrelated" failure with an isolated rerun.

## Review criteria

Exactly six fields with no seventh and no companion file; `env` values
refused with the field named; refusals in the manifest idiom; `requires`
demonstrably consumed by the existing matcher in **both** directions;
no orchestration or spawning; no formatter churn; counts reconciled
per-app against 3,458.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). ⚠️ Not
reachable from inside the sandbox — a capability boundary, not a defect.
Report identities; the reviewer files them. ⭐ **And if this round needs
a capability the sandbox denies, NAME IT rather than working around its
absence.**

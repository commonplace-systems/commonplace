# BUILD BRIEF — CX-2jfb (part 1): sign the Bursar's RedLog writes, and stop discarding the refusal

**For:** Sol (codex)
**Ticket:** **CX-2jfb** (p2/bug) — this brief is **Tier A + Tier B only**
**Worktree:** `/home/jes/sol-2jfb/wt` · **branch:** `sol/cx-2jfb`
**Run log:** `/home/jes/sol-2jfb/sol-run.log` (beside the worktree, not inside)

---

## 0. Environment contract (standing)

Named worktree off **current** `origin/main`; ⛔ git metadata read-only,
**leave changes UNSTAGED**, no `git add`, no commit, **do not work around
`index.lock`**; ⛔ no serve/store route — **build fixture stores**; every suite
via `bin/cp-test-guard --min N --apps N -- <cmd>`, **one at a time** (shared
`tmp/test_data`); ⚠️ **rc from the command itself, never a pipe**; ⚠️ **a count
from a piped listing is not a count**; ⚠️ **a default limit is a scope the
number doesn't mention** — if you call a reader with `[]`, say so.

## 1. ⛔ EVERY SITE HAS **TWO** DEFECTS. FIXING ONE LEAVES THE SYSTEM EQUALLY BLIND.

`RedLog.commit/1`:

```elixir
def commit(%__MODULE__{} = log) do
  _ = do_commit(log, [])   # ① no opts  ⇒ UNSIGNED
  log                      # ② return discarded ⇒ REFUSAL UNOBSERVABLE
end
```

`commit/2` exists and was built as the remedy — **1 of 9 call sites uses it.**
Its own docstring predicted this: *"the log silently stops recording exactly
when enforcement turns on."*

⇒ **Sign it and you stop losing writes. Inspect the result and you stop losing
the KNOWLEDGE that a write was lost.** ⛔ A write refused for some *other*
reason (bad chain, gate change, disk) still reports nothing if you only fix ①.
**Both, at every site in scope, or the change is not done.**

## 2. Scope — exactly three call sites

| # | Site | Tier | Context |
|---|------|------|---------|
| 1 | `green/bursar.ex:827` (`log_event/5`) | A | `sign_opts(state)` — **defined at :823-824, four lines above** |
| 2 | `green/bursar.ex:886` (`create_log_doc/2`) | A | same |
| 3 | `commonplace_bots/.../worker.ex:272` (`maybe_write_red_log/5`) | B | module mentions `signing_context` 12×; `opts` is in scope at the call |

⛔ **OUT OF SCOPE — do not touch, do not "while I'm here":**
`merge_command/handler.ex:318`, `bd/frontier/server.ex:162`,
`bd/frontier/server.ex:208`, `process/sandbox_exec_runner.ex:149`,
`process/sandbox_exec_runner.ex:189`. Those are **Tier C** and need a written
decision about *whose* identity signs. **Report anything you notice; fix
nothing there.**

⭐ **THE DISCRIMINATOR IS PER-CALL-SITE, NOT PER-MODULE.** The Bursar *does*
hold a node `SigningContext` (`:335`) and *does* thread it into all four of its
direct `CommitStoreClient` writes. "Does this module sign?" is the wrong
question and it is the one everyone asks. Answer it per call.

## 3. ⚠️ SITE 2 IS NOT JUST A SIGNING FIX — IT IS A HALF-LANDED TRANSACTION

`create_log_doc/2`:

```elixir
uuid = UUID.uuid4()
log = RedLog.new(uuid, state.store)
RedLog.commit(log)                              # UNSIGNED → refused under enforce
...
schema = Schema.add_file(schema, @log_doc, uuid)
CommitStoreClient.create_chained_commit(..., sign_opts(state))   # SIGNED → LANDS
```

⇒ **The pointer lands and the doc does not.** Two writes that needed to be one
operation, **whose halves have different authority** — the gate did not cause
this, it made a latent asymmetry visible by refusing exactly one half.

**MEASURED LIVE 2026-08-09:** five docs denied on the current boot have **ZERO
commits in the store** —
`0bc5272f-…`, `4a4ea739-…`, `812ae828-…`, `8537c0db-…`, `a0d133ef-…` — each
with exactly two denials (236 then 78 bytes). Uuids something minted,
referenced, and never persisted.

⛔ **So site 2 needs BOTH: pass the context AND make the schema entry
conditional on the doc write landing.** Signing alone leaves the pattern intact
for the next thing refused for any other reason.

## 4. ⭐ THE ACCEPTANCE ITEM MOST LIKELY TO BE DROPPED

The damage splits into two classes with **inverted detectability**:

- **orphan** (doc never existed) — **detectable**; a dangling entry announces
  itself to anything walking the tree.
- **lost update** (doc healthy, one write refused) — **undetectable**; doc
  fine, schema fine, commit never happened, *nothing points at its absence.*

⇒ **The loud damage is the recoverable kind; the silent damage is the permanent
kind.** A repair that fixes the orphans, walks the tree and sees it clean will
read as complete while class (b) is untouched — **a clean tree is exactly what
class (b) looks like.**

⇒ **This is what makes defect ② (the discarded return) load-bearing rather than
cosmetic.** It is the only thing that can surface a lost update.

## 5. Acceptance — red-first, paste real output

1. ⭐ **RED FIRST, AND IT IS THE TICKET:** a test that a **Bursar
   denial-log write LANDS under enforce** (`accept_unsigned: false`).
   **Demonstrate it FAILING on today's code** — paste the red. `log_event/5`
   is what `log_denied/4` calls, so today **the record of a denial is itself
   denied**.
2. **A refused log-doc creation must NOT leave a schema entry pointing at a
   commit-less doc.** Test it. This is the live-observed damage from §3.
3. ⭐ **A refused write must be OBSERVABLE at all three sites.** Assert on
   what the caller does with `{:error, _}` — ⛔ **not merely that `commit/2`
   was called.** A test that only checks the arity is a test of the diff.
4. ⛔ **THE CONTROL MUST BE ABLE TO GO RED.** For each of the three sites,
   show the new test fails when you revert that site alone. **Three reverts,
   three reds, pasted.** One shared test that passes if any site is fixed is
   the failure mode here.
5. Named suites green, with counts, **one at a time**:
   - `apps/commonplace/test/commonplace/green` — record the count on main first
   - `apps/commonplace/test/commonplace/dataflow` — likewise
   - `apps/commonplace_bots/test` — likewise
   ⚠️ **Establish each baseline on main BEFORE your change**, and report both
   numbers. A suite whose count changed silently is a finding.
6. `mix compile --warnings-as-errors` rc=0.
7. **Name anything you could not verify in-sandbox** and stop rather than
   approximating. ⚠️ You have **no serve and no node signing key** — the key is
   masked to a 0-byte file. Anything needing a real node identity must be a
   fixture; **say so rather than working around it.**

## 5b. ⛔ HOW TO RUN A LONG SUITE IN THIS SANDBOX — READ BEFORE YOUR FIRST TEST RUN

⚠️ **EACH `exec` YOU RUN GETS A FRESH PID NAMESPACE.** `ps` inside one exec
shows `bwrap` as PID 1 and **nothing from any other exec**. ⇒ **A process you
started in a previous command is STRUCTURALLY INVISIBLE to `ps`/`pgrep` in the
next one.**

⛔ **SO NEVER POLL `ps` TO ASK "IS MY TEST STILL RUNNING?"** The answer is
always "not found", and "not found" reads identically to "finished" and to
"never started". A previous run of this brief burned its entire budget in that
loop, concluding each time that there was "no safe basis to call it hung."
⭐ **THAT IS THE FENCE PRODUCING A NEGATIVE THAT LOOKS LIKE A FINDING** — the
exact hazard §7 warns about, in the tooling rather than the subject.

**Do this instead — make the run leave an artifact you can read:**

```bash
bin/cp-test-guard --min N --apps 1 -- mix test <path> > /tmp/t-<name>.log 2>&1
echo "RC=$?"
```

Run it in the FOREGROUND and let it block. It is a first full compile; it can
take many minutes and produce no output until it finishes. **That is expected
and is not evidence of a hang.** If you must check progress, `wc -l` the
redirect file — **poll the ARTIFACT, never the process table.**

## 6. Out of scope

- Tier C sites (§2) — **report, don't fix.**
- Attribution of denials to a writer (**CX-8fyq**) and canary exclusion
  (**CX-7kx7**) — separate tickets, do not anticipate them.
- The class-(b) detector — designed separately; **do not build it here.**
- Any other defect: **report it, don't fix it.**

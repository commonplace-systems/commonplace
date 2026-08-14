# CX-v1zh instance 3 of 3: `bin/bd` — the refusal is real and the reflex bypasses it

> **The work's ticket is CX-v1zh.** Base: **the commit that adds this brief**
> — ⚠️ *not a sha; committing a brief moves HEAD past any sha it records.*
>
> ⛔⛔ **LAST INSTANCE. STOP AND REPORT.**

## ⛔⛔⛔ CARRY THIS PRIOR IN, RATHER THAN DISCOVERING IT A THIRD TIME

**Both earlier instances of this ticket MISATTRIBUTED the protection they were
about, and each wrong attribution was written down confidently.**

| instance | claimed cause | actual cause |
|---|---|---|
| load-order | "Trust already loaded" | **the newer-than-serve set was EMPTY** (a deploy) |
| PID-ns | `--unshare-pid`, then "+ `--proc /proc`" | ⛔ **NEITHER — the USER namespace bwrap creates implicitly** (`CX-q8f1`) |

⭐⭐ **THE TICKET EXISTS BECAUSE ACCIDENTAL PROTECTIONS EXPIRE QUIETLY — AND WE
HAVE NOW FAILED TO NAME THE ACCIDENT'S CAUSE TWICE.** ⇒ ⚠️ **Treat this
ticket's description of instance 3 as a HYPOTHESIS, not as a premise.**
⭐ **The specific trap both times: a measurement that was TRUE and answered a
NEIGHBOURING question.** *The 08-13 run really did show `--unshare-pid` alone
leaves `/proc` host-backed — it measured PID VISIBILITY while the claim was
about CREDENTIAL READABILITY.* ⛔ **Ask of every number: does this answer the
question being asked of it, or a question next to it?**

## ⚠️ AND I ALREADY RE-DERIVED PART OF IT — THE TICKET'S PREMISE IS WRONG AS STATED

**The ticket says:** *"`bin/bd` is safe on Sol only because a fresh worktree
lacks a Dolt DB. The archive-write reflex is blocked by the absence of a
database, not by a refusal."*

⛔ **Measured 2026-08-14 — there IS a refusal, and it predates the ticket by
five days** (`bin/bd`, written 2026-08-08):

```
bin/bd create --title=x   →  "⛔ bd is the FROZEN ARCHIVE ... 'create' is a WRITE"   rc=1
```

⭐ **`bin/bd` refuses `create|update|close|reopen|delete|dep|label|claim|release`
unconditionally, and refuses READS unless `CP_BD_ARCHIVE=1`.** *That is a real,
designed refusal — not an absence.*

## ⭐⭐ BUT HERE IS THE PART THAT MAKES THIS AN INSTANCE AFTER ALL

```
command -v bd            →  /home/jes/.local/bin/bd     ← the REAL binary
repo bin/ on PATH?       →  NO
```

⛔⛔ **SO THE WRAPPER IS NEVER CONSULTED FOR A BARE `bd`.** ⇒ ⭐⭐ **THE
GUARDRAIL BUILT TO CATCH THE REFLEX ONLY FIRES IF YOU ALREADY KNOW TO TYPE
`bin/bd`** — *it protects the people who did not need protecting and misses the
reflex it exists for.* ⚠️ **And a bare `bd` is exactly what the plugin/hooks
still suggest at session start.**

⇒ **So the ticket's claim is FALSE for `bin/bd` and MAY BE TRUE for bare `bd`,
where the only remaining protection on Sol is the missing database.**
⭐ **THAT SPLIT IS YOUR SUBJECT. Establish it or refute it.**

## ⛔⛔ THE ONE THING YOU MUST NOT DO, AND THE OBVIOUS TEST IS IT

**DO NOT RUN `bd create` / `update` / `close` — NOT EVEN TO SEE IT FAIL, NOT
EVEN IN A THROWAWAY WORKTREE.**
⚠️ **The obvious way to test "is the write blocked" is to attempt the write.**
⛔ **In a directory with no Dolt DB, the real `bd` may MINT ONE** — which
*creates a second divergent archive*, i.e. the test manufactures the harm the
protection exists to prevent. ⭐ *This is the half-fix control's shape: the
naive implementation produces the defect.*

⇒ **Establish the mechanism WITHOUT invoking a write:** resolution order
(`command -v`, `type -a`), the wrapper's own `case` arms, whether `.beads/`
exists in a fresh worktree, and what the real binary does on a *read* in a
DB-less directory. **If you cannot settle a question without a write, SAY SO
AND LEAVE IT OPEN.**

## ⭐ WHERE EACH ARM RUNS — stated, because instance 2 could not run its own

⚠️ **Instance 2's red arm was impossible from inside the sandbox: the outer
fence dominated the thing under test.** ⭐ **THIS ONE IS DIFFERENT — the subject
(`bd`, `PATH`, a fresh worktree) is INSIDE the fence with you, so your arms run
where you are.** ⇒ **Say which arm ran where, and if any arm cannot run from
inside, NAME IT rather than substituting one that can.**

## ⛔ Acceptance — both halves

1. ⭐⭐ **A TRUE POSITIVE: the check FAILS when the protection is absent.**
   *Construct the absent condition — do not assert it.*
2. ⭐⭐ **A TRUE NEGATIVE: with the protection intact, the check PASSES, and its
   corpus is proven.** ⛔ **A check that finds no `bd` at all also "passes".**
   ⇒ **Assert the binary was FOUND before asserting it was refused.**
3. ⭐ **TEST THE CAPABILITY, NEVER THE HANDLE.** *Not "does `bin/bd` contain a
   `die` call" — **can the archive still be written from here?*** ⚠️ **A flag
   grep would have been wrong TWICE in instance 2; a source grep is the same
   move.**
4. **The failure NAMES what it found reachable** — which binary, by which path.
5. **The script LANDS AS A FILE and its own run output is reported.**

## ⚠️ The honest limit — answer it

**This ticket makes removal NOISY; it does not make the protection
INTENTIONAL.** ⭐ **Here the deliberate fix looks unusually cheap — putting the
repo's `bin/` ahead of `~/.local/bin` on PATH would make the existing refusal
actually intercept the reflex.** ⛔ **DO NOT DO IT — that is an environment
change, not a round's work.** ⇒ **State whether it is as cheap as it looks, and
what it would break.**

## Suites

Core baseline **3,494 / 0 / 1 skipped** at **seed 117514** — *falsifiable,
measure your own.* ⛔ **REPORT THE SEED.** ⛔ **Never pipe a long `mix test`.**
⚠️ **`mix format --check-formatted` is ALREADY RED on main (`CX-y8j6`) — do not
"fix" it and do not let it read as yours.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact.**
- ⛔ **Never `bd create|update|close`, in any directory, for any reason.**
- ⛔ **Do not edit `sol-egress-run.sh`.** ⛔ **Do not change PATH permanently.**
- ⛔ **Do not run `mix format` or `mix precommit`.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION** — *and its author has now
  been wrong about this ticket's mechanism twice.* ⛔ **REPORT DISCREPANCIES
  rather than satisfying the claim.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to attempt a write to
  see it refused.

## Review criteria

Both directions demonstrated; the check asserting reachability rather than
source text; a corpus control proving `bd` was found; the bare-vs-`bin/`
resolution split settled; and no write attempted.

# BUILD BRIEF — CX-rp33: per-stage counters in `AuditLog.handle_event/4`

**For:** Sol (codex)
**Ticket:** **CX-rp33** (p1/bug)
**Worktree:** `/home/jes/sol-rp33/wt` · **branch:** `sol/cx-rp33`
**Run log:** `/home/jes/sol-rp33/sol-run.log` (beside the worktree)

---

## 0. Environment contract (standing)

Named worktree off **current** `origin/main`; ⛔ leave changes **UNSTAGED**, no
`git add`, no commit, no push; ⛔ **no serve, no live store** — the live store is
`/home/jes/commonplace/workspace/.commonplace/commits/`, **process-derived, NOT
repo-root and NOT `data/`** (that path exists and is a **stale decoy** an escript
bug minted). **Build fixture stores.**

Suites via `bin/cp-test-guard`, **one at a time**; ⚠️ **rc from the command
itself, never through a pipe** — `mix test … | tail` gives you `tail`'s rc, which
is always 0. ⚠️ **A count from a piped listing is not a count.** ⛔ Each `exec`
gets a **fresh PID namespace** — redirect long runs to a file and read the file.
⚠️ **A fresh worktree needs `mix deps.get` first** (you have network).

⛔ **NO BARE ZEROS.** Any `0` arrives with a **positive control that the pattern
matches something.**
⛔ **EVERY CONTROL THAT WORKS BY REMOVING SOMETHING NEEDS ITS OWN CONTROL** — if
you show behaviour "when X is absent", **prove X was absent.**

## 1. ⛔ THE DELIVERABLE IS SIX COUNTERS AND A TABLE SHOWING THEM DISAGREE

**This is an ADD-A-FIELD + FILL-A-TABLE ticket.** ⭐ **Report measurements. Do
not explain mechanisms, and do not diagnose any historical incident.**

`Commonplace.Trust.AuditLog.handle_event/4` (audit_log.ex:189-238) runs an event
through several stages that can each drop it. **Today only the two ENDS are
observable** — events in, records out — so any loss is unlocalisable.

**Add a counter at each stage boundary and expose them in one read.**

## 2. The stages — read them from the code, this list is a guide not a spec

From `handle_event/4` as it stands on `main`:

| stage | where |
|---|---|
| `entered` | top of `handle_event/4`, before anything can drop it |
| `guarded` | `recursion_guard(payload)` true branch (the `GenServer.cast`) |
| `rate_suppressed` | `rate_gate/1` returns `:suppress` |
| `offered` | each `AuditDispatcher.offer/2` call |
| `handler_failed` | the `rescue`/`catch` → `handler_failure/2` path |

⚠️ **`{:log, summary}` offers TWICE** (summary + payload). ⭐ **Count offers, not
events, and say which you counted** — a counter whose unit is ambiguous is worse
than none.

⚠️ **`accepted_by_dispatcher` and `committed` live in `AuditDispatcher`, not
here.** ⭐ **If reaching them requires changing the dispatcher's interface, STOP
and report that** — do the `handle_event/4` side, report the boundary you hit.
**A partial instrument that is honest about its edge is the deliverable; a
guessed one is not.**

## 3. ⚠️ Mandatory properties

1. ⛔ **PER-BOOT, AND IT MUST SAY SO** — carry `boot_id`, the same one the
   existing denial counter uses. ⭐ **A lifetime aggregate cannot answer a
   question about NOW.** That error was made twice this week.
2. **One read returns all of them** — a function returning a map. The point is
   that a person under time pressure gets the whole shape in one call.
3. ⛔ **DO NOT COMPUTE A CAPTURE RATE OR ANY RATIO.** ⚠️ **`Trust.capture_rate/1`
   shipped a ratio across two populations and had to be fixed AFTER deploy; its
   refusal branch is in `trust.ex` — read it before you write anything here.**
   **Counters only. Ratios are a separate decision.**
4. **Follow the existing counter's storage pattern** (`Trust.DenialCounter` —
   `:atomics` in `:persistent_term`). ⭐ **Do not invent a second mechanism.**

## 4. ⛔ ACCEPTANCE — THE COUNTERS MUST BE SHOWN TO DISAGREE

⭐⭐ **THE CENTRAL CRITERION: six counters that always read equal prove nothing.
That is a check that cannot fail, and it would read as evidence.**

**Fill this table by construction, one test per row:**

| provocation | which counter increments | which does NOT |
|---|---|---|
| ordinary denial, under cap | ? | ? |
| denial naming the audit log's own doc | ? | ? |
| denials past `@cap` in one window | ? | ? |
| `build_payload` raises | ? | ? |

⇒ **Each row: the counter values before and after, pasted raw.**
⛔ **Every row must show at least one counter that did NOT move.** A row where
everything increments together has not discriminated anything.

**Also required:**
1. ⭐ **RED-FIRST:** show the counters' absence first — paste the current read.
2. **`entered` > sum-of-terminal-stages must be impossible** — assert the
   arithmetic closes on at least one multi-event run.
3. ⛔ **The `rate_suppressed` row needs `@cap` read AT THE CALL SITE, not
   assumed.** ⚠️ *The default is not the value.*
4. `mix compile --warnings-as-errors` rc=0, and — **baseline first, report both
   numbers, one suite at a time:**
   - `apps/commonplace/test/commonplace/trust` — **197 tests, 0 failures on
     main** *(measured 2026-08-09 14:59, rc=0 unpiped — not 195/196, which are
     stale numbers in older briefs)*
   - `apps/commonplace/test/commonplace/store` — **5 doctests + 450 tests, 0
     failures on main**

## 5. ⛔ OUT OF SCOPE — do not widen

- ⛔ **Do NOT change `recursion_guard/1`, `rate_gate/1`, the dispatcher, or any
  drop behaviour.** ⭐ **Counters observe; they do not decide.** If you find
  yourself changing what gets dropped, the scope has drifted — stop.
- ⛔ **Do NOT investigate the 2026-08-06 incident**, read `serve.log`, or explain
  why any historical record is missing. ⭐ **This instrument exists because that
  question is unanswerable; answering it is not this ticket.**
- ⛔ **Do NOT add a ratio, a rate, or a "health" verdict.**
- Any other defect: **one line, don't pursue it.**

## 6. What you cannot verify in-sandbox

- ⛔ **Anything requiring the live serve** — report **UNVERIFIED** and stop; do
  not approximate. The counters' behaviour under real load is my check, not
  yours.
- This ticket needs **no trust anchor and no signing**. ⭐ **If you find yourself
  wanting one, stop and say so** — it means the scope has drifted.

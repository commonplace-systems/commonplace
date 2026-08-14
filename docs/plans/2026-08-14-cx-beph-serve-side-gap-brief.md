# CX-beph build brief: the serve-side deploy gap must surface WITHOUT ANYONE ASKING

> **The work's ticket is CX-beph.** Base: **the commit that adds this brief**
> — ⚠️ *not a sha; committing a brief moves HEAD past any sha it records.*
>
> ⭐⭐ **THIS TICKET IS CURRENTLY DEMONSTRATING ITSELF ON THE LIVE SERVE. The
> fixture below is REAL, not synthetic, and it is being held in place for you.**

## ⛔⛔ THE LIVE FIXTURE — measured 2026-08-14 18:15Z, and it is being preserved

```
serve pid 1153034, started Thu Aug 13 21:26:39   (up 20h48m, launch commit 84475d91)
bin/cp-deploy-gap  →  WOULD-DEPLOY-ON-RESTART: 10 beam(s) newer than that start
all 10 beams written 2026-08-14 17:17:03–04      ← an ordinary `mix test` run
```

⭐ **`mix test` COMPILES.** ⇒ **That is the same mechanism `CX-h062` was about,
and here it produced the SERVE-side hazard rather than a false CI red.**

**Six of the ten are NOT resident, so the next touch loads today's beam**
(probed with `:code.is_loaded/1` only; `all_loaded` **701 → 701**, so the probe
perturbed nothing):

```
NOT loaded:  MudLive · ChatRoomLive · MUD.PlayerSession · MCP.Tools ·
             MCP.Tools.ListPeers · CLI.Access
loaded:      Bd.Invariants · SafeVerb.Allowlist · LockRefusal · Bots.Dispatcher
```

⚠️ **SEVERITY, HONESTLY — do not overstate it in your report either.** Only
**15 files changed** between `84475d91` and main, and **none of the four
user-facing not-resident modules is among them**: `mud_live.ex`,
`chat_room_live.ex`, `player_session.ex`, `mcp/tools.ex` are all **source-
identical**. ⇒ **They would load byte-different artefacts of identical source.**
⭐ **The mixed-serve hazard is real as a CLASS and near-empty in THIS instance.**
*(Only `cli/access.ex` differs, and it is a CLI module the serve does not load
on a user touch.)*

## ⭐⭐ WHY THIS BEATS ANY ARGUMENT FOR THE TICKET

```
the ticket predicted it IN WRITING   "the first compile-without-restart makes it
                                      FALSE, and nothing will announce that"
time to occur                         under FOUR HOURS
who triggered it                      the ticket's own holder
who had shipped the fix for this
  exact mechanism 4h earlier          the same person
how it was found                      by re-deriving a premise, NOT by noticing
how long it was invisible             ~1 hour
```

⛔ **"Someone must think to run it" FAILED ON THE PERSON BEST PLACED TO THINK OF
IT.** ⇒ ⭐ **That is not a lapse, it is the argument: a pull-only check is
insufficient BECAUSE the people who know most about it are the ones generating
the condition while their attention is elsewhere.**

## ⛔⛔ WHERE EACH ARM RUNS — read this before designing anything

**A SANDBOXED ROUND STRUCTURALLY CANNOT SEE THE SERVE.** Your PID namespace
hides the host's processes; `cp-deploy-gap`'s serve-detection will not find it.
⚠️ **This is the exact positional failure that cost `CX-v1zh` instance 2 a
round** — its red arm was impossible from inside the fence and the reviewer had
to run it on the host.

⇒ **SO, EXPLICITLY:**
- ⭐ **YOU build the mechanism and prove BOTH directions against an EXPLICIT
  reference** (`--since`, `CP_BUILD_DIR`) — a synthetic reference you control.
- ⛔ **THE LIVE-SERVE ARM IS THE REVIEWER'S. Do not attempt it, and do not
  report a live measurement you could not have taken.**
- ⭐ **State which arm ran where.** *If something can only be verified live, NAME
  IT as owed rather than substituting a check you can run.*

## ⛔ WHAT NOT TO DO — these are writes wearing a measurement's clothes

- ⛔⛔ **DO NOT RUN `mix compile`.** *It is a WRITE THAT MOVES THE DEPLOY
  BOUNDARY — `cp-deploy-gap`'s own header says so. It would also destroy the
  live fixture being held for this ticket.*
- ⛔⛔ **DO NOT RESTART THE SERVE.** *A restart IS the deploy; it is the host
  owner's act, and it is already scheduled for after this lands.*
- ⛔ **DO NOT "load everything at boot"** — *that converts a lazy partial deploy
  into an eager full one, which is a deploy, not a fix. The ticket says so.*
- ⛔ **DO NOT PERTURB THE LIVE SERVE.** *Its module set is the subject; a probe
  that loads a module makes the finding true by making it happen.* ⭐ If a live
  read were ever needed: `:code.is_loaded/1` ONLY — never
  `Code.ensure_loaded?/1` or `module_info/1`, **both of which AUTO-LOAD** — and
  report an `:code.all_loaded` before/after delta.
- ⚠️ **AND A NEW ONE, EARNED TODAY: FENCING THE VERB IS NOT FENCING THE EFFECT.**
  *A previous brief forbade `bd` writes and authorised a read; the READ created
  a database. Before running anything you have classified as a measurement, ask
  what it WRITES.*

## ⭐ The acceptance

1. ⭐⭐ **THE NON-ZERO CONDITION PRODUCES OUTPUT SOMEBODY SEES WITHOUT RUNNING A
   COMMAND.** ⇒ **State WHERE it lands and WHY that is somewhere a human already
   looks.** *Options, not a decision: a boot-time assertion in the serve; a
   periodic check reporting into the statusline or squad; a deploy-ceremony step
   that fails.* ⛔ **A thing that only prints when invoked is what we already
   have.**
2. ⭐⭐ **RED-FIRST BY DELIBERATE PERTURBATION — CAPTURE THE ORIGINAL MTIME
   FIRST.** Touch one beam, observe the noise; restore the mtime, observe it
   stop. **BOTH VERBATIM.** *(Known to work: 0 → 1 → 0, measured 2026-08-13
   21:28Z.)*
3. ⭐⭐ **AND THE QUIET HALF, WHICH IS WHY `CX-h062` EXISTS: a normal state must
   NOT produce noise.** ⛔ **A notifier that fires when the gap is 0 is worse
   than none — it trains everyone to ignore it, exactly as `--no-compile` did.**
4. **It NAMES which beams**, as `--assert-empty` already does.
5. **Lands as files; report their own counts from the tree.**

## ⭐⭐ THE REFERENCE — say WHY it is right, do not re-derive it

**`CX-h062` removed a CI arm because it borrowed the serve's reference for a
test VM.** ⇒ ⭐ **HERE THE SAME REFERENCE IS CORRECT, AND THE ROUND'S JOB IS TO
SAY WHY:** *the serve does not compile after it starts, so any beam newer than
its start is code it was not built with, and lazily loading one is an unplanned
partial deploy.*
⚠️ **THE RISK HERE IS THE MIRROR OF `CX-h062`'s: not shipping a wrong reference,
but failing to state why THIS one is right.** ⛔ **An unexplained correct check
is the one a future round removes as unjustified** — *and this project has now
done exactly that once today.*

## ⚠️ THE HONEST LIMIT — answer it BEFORE you build

**This makes the serve's loss-of-protection NOISY. It does not make the
protection DELIBERATE.** ⭐ **The stronger fix — restart-on-compile, or a serve
that REFUSES to lazily load a beam newer than its own start — is larger.**
⛔ **ASK WHETHER THAT IS AFFORDABLE BEFORE BUILDING THE NOISE**, because ⭐ *a
guard that lands first can foreclose the better fix by removing the symptom that
would have motivated it.* ⇒ **State your answer; do not build both.**

## Suites

Core baseline **3,494 / 0 / 1 skipped** at **seed 117514** — *falsifiable,
measure your own.* ⛔ **REPORT THE SEED.** ⛔ **Never pipe a long `mix test`.**
⚠️ **`mix format --check-formatted` is ALREADY RED on main (`CX-y8j6`) — not
yours; do not fix it.**
⚠️ **AND NOTE THE RECURSION: running the suite is what CREATED the live fixture.
Your suite run recompiles inside your own sandbox build dir, not the host's —
but say so rather than assuming it.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact.**
- ⛔ **Do not run `mix format` or `mix precommit`.** ⛔ **Do not edit
  `sol-egress-run.sh`.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION** — *its author shipped the
  gate this ticket's parent had to remove, and created the live fixture above by
  accident.* ⛔ **REPORT DISCREPANCIES rather than satisfying the claim.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to run `mix compile`,
  or to report a serve-side number you could not have measured.

## Review criteria

Output that arrives unasked, with its landing place justified; both directions
demonstrated against an explicit reference; the reference explained for the
serve specifically; the stronger-fix question answered before building; and a
clear statement of which arm ran where.

# BUILD BRIEF — CX-2jfb Tier C sites 2–3: sign the frontier server's writes

**For:** Sol (codex)
**Ticket:** **CX-2jfb** (p2/bug) — Tier C **sites 2 and 3 only**
**Worktree:** `/home/jes/sol-front/wt` · **branch:** `sol/cx-2jfb-frontier`
**Run log:** `/home/jes/sol-front/sol-run.log` (beside the worktree)
**Decision already made:** `docs/plans/2026-08-09-cx-2jfb-tier-c-decision.md`
(@678f879) — **NODE identity, degrade don't die.** Do not re-open it.

---

## 0. Environment contract (standing)

Named worktree off **current** `origin/main`; ⛔ git metadata read-only,
**leave changes UNSTAGED**, no `git add`, no commit, no push; suites via
`bin/cp-test-guard`, **one at a time**; ⚠️ rc from the command itself, never a
pipe; ⚠️ **a count from a piped listing is not a count**; ⚠️ **the default is
not the value** — read constants at the **call site**.

⛔ Each `exec` gets a **fresh PID namespace** — a process started by one
command is invisible to `ps`/`pgrep` in the next. **Redirect long runs to a
file and read the file. Never poll the process table.**

## 1. ⛔⛔ READ THIS FIRST: SIGNING ONLY HALF OF SITE 3 *CREATES* A DEFECT THAT DOES NOT EXIST TODAY

`ensure_log_file/3` (`bd/frontier/server.ex` ~:203-213) does **two** writes and
**both are currently unsigned**:

```elixir
uuid = UUID.uuid4()
log  = RedLog.new(uuid, store)
_ = RedLog.commit(log)                                        # ← unsigned (commit/1)
schema = Schema.add_file(schema, filename, uuid)
update = Encoding.encode_update(schema)
CommitStoreClient.create_chained_commit(store, bd_uuid, update)  # ← unsigned (3-arg, no opts)
```

⇒ **Under enforce both are refused together, so there is NO dangling pointer
today** — the doc isn't created *and* the entry isn't written. The site fails
completely and honestly.

⛔ ⭐ **THE TRAP: sign the RedLog write and leave the schema write unsigned and
you get the opposite — the log doc lands and the pointer does not. Sign the
SCHEMA write and leave the log write unsigned and you reproduce EXACTLY the
Bursar defect measured live: a schema entry pointing at a doc with ZERO
commits (five such docs on the live serve).**

⇒ **Both writes must be signed, and the schema entry must additionally be
GATED on the log write landing.** ⚠️ *(This corrects the Tier C decision doc,
which said `:208` "reproduces the dangling-pointer defect." It does not,
**yet** — and a half-fix is what would introduce it.)*

## 2. Scope — exactly two sites

| # | Site | What |
|---|------|------|
| 2 | `bd/frontier/server.ex:162` (`handle_info`) | `RedLog.commit/1` → `commit/2`, node-signed, **result inspected** |
| 3 | `bd/frontier/server.ex:~208` (`ensure_log_file/3`) | both writes signed, **schema entry gated on the log write landing** |

⛔ **OUT OF SCOPE:** `merge_command/handler.ex:318` (deferred, @678f879) and
`process/sandbox_exec_runner.ex:149`/`:189` (**already done** — CX-hk0s
@f194946). **Report anything you notice; fix nothing there.**

⭐ **Two defects per site, as with Tier A+B (@be28010):** `commit/1` passes no
opts (**unsigned**) *and* discards the return (**the refusal is
unobservable**). **Fixing one leaves the system equally blind.**

## 3. Whose identity, and what if it is unresolvable

- **Whose?** The **node**. `Frontier.Server` is a projection maintaining the
  node's own derived view; it acts on **nobody's** behalf. ⭐ This is the one
  Tier C site where a node context is the honest answer rather than the
  convenient one — **it needs none of the agent-identity machinery and must
  not grow any.**
- **Unresolvable?** ⛔ **Log loudly and continue with a stale frontier. NEVER
  exit.** `:162` is a `handle_info`; `:208` is on the log-file creation path.
  ⚠️ **A ticket tracker whose frontier server crash-loops is worse than one
  whose frontier is stale** — the frontier is advisory, the tracker is not.
  ⭐ This is the codebase's own rule, stated in `AuditDispatcher.offer/2`:
  *"losing its RECORD must never turn into losing its ENFORCEMENT."*

⚠️ **Testability:** `start_link/1` → `init/1` already threads `opts`
(`Keyword.get(opts, :store, …)`), so add an **injectable
`opts[:signing_context]`** falling back to `NodeIdentity.signing_context/0` —
the same seam Sol added to the Bursar for CX-2jfb. **You need it: see §5.**

## 4. ⛔ ACCEPTANCE — red-first, and the negatives are the ticket

1. ⭐ **A refused log-doc creation leaves NO schema entry.** ⛔ **Assert the
   entry is ABSENT** — `Schema.get_entry(schema, filename)` returns `:error`.
   ⚠️ **DO NOT assert "the caller errored."** *"It failed"* and *"it left no
   dangling pointer"* are **different claims** and only the second is about
   this fix — a test on the first passes for a version that writes the entry
   and then returns an error.
2. ⭐ **THE HALF-FIX CONTROL, and it is the point of §1:** sign the schema
   write while leaving the log write unsigned, and show a test goes **RED**
   with a schema entry pointing at a zero-commit doc. **That is the defect
   this brief exists to avoid introducing** — prove your version prevents it.
3. **A refused write at `:162` is OBSERVABLE** — assert on what the caller does
   with `{:error, _}`, ⛔ **not merely that `commit/2` was called.**
4. **The server does not exit on a refused write.** Assert it is still alive
   and still processing after one.
5. ⛔ **Each site reverted ALONE and shown red.** ⚠️ **A combined revert proves
   the SET is load-bearing; individual reverts prove EACH ONE is.**
6. `mix compile --warnings-as-errors` rc=0. Named suites, **baselined on main
   first**, one at a time, both counts:
   - `apps/commonplace/test/commonplace/bd`
   - and the existing `frontier_server_test.exs` count specifically

## 5. ⚠️ WHAT THE FENCE MASKS — read your negatives, don't believe them

- ⛔ **`node_signing_key` is masked to a 0-byte file**, so
  `NodeIdentity.signing_context/0` **FAILS** and the anchor set is **empty**.
  ⇒ **A node-signed write cannot succeed in this sandbox.**
- ⇒ ⭐ **The DEGRADE half is fully exercisable in here; the SUCCESS half is
  not — unless you use the injectable `opts[:signing_context]` from §3 with a
  FIXTURE context and a fixture anchor.** **Use fixtures. That is what the
  seam is for.**
- ⛔ **A refusal you see in here is the fence, not a signing defect.** Do not
  report it as one and do not "fix" it.
- ⭐ **And the inversion worth stating: in this sandbox a real node-signed
  write FAILING is expected. If one appears to SUCCEED, disbelieve it** — that
  would mean the mask is not applying, which is a finding about the harness.
- Also masked: no serve, no store route, no erlang cookie, read-only HOME.
- **If something cannot be verified here, SAY SO AND STOP rather than
  approximating.**

## 6. Out of scope

- The other Tier C sites (§2).
- Any change to the anchor set, the delegation root, or agent identity.
- Any other defect: **report it, don't fix it.**

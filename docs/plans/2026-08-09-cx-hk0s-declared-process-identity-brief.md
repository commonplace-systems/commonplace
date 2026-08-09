# BUILD BRIEF — CX-hk0s: give a declared process its own signing identity

**For:** Sol (codex)
**Ticket:** **CX-hk0s** (p2/feature) — this brief is the **declared-process
caller** only
**Worktree:** `/home/jes/sol-hk0s/wt` · **branch:** `sol/cx-hk0s`
**Run log:** `/home/jes/sol-hk0s/sol-run.log` (beside the worktree)

---

## 0. Environment contract (standing)

Named worktree off **current** `origin/main`; ⛔ git metadata read-only,
**leave changes UNSTAGED**, no `git add`, no commit, no push; ⛔ no serve/store
route — build fixture stores; suites via `bin/cp-test-guard`, **one at a
time**; ⚠️ rc from the command itself, never a pipe; ⚠️ **a count from a piped
listing is not a count**; ⚠️ **the default is not the value** — read constants
at the **call site**, not the definition.

⛔ **Each `exec` gets a FRESH PID NAMESPACE.** A process started by one command
is invisible to `ps`/`pgrep` in the next. **Redirect long runs to a file and
read the file. Never poll the process table.** A first full compile takes many
minutes with no output; that is expected, not a hang.

## 1. ⛔ WHAT IS ALREADY BUILT — do not design any of this

**The actor model exists and is in production** (MUD bots, chat, git_bridge,
MCP, web sessions). **You are wiring ONE more caller into it.**

    Presence.Identity.register_agent/4    registers a :bot identity,
                                          AgentKeys.ensure (MINTS ONCE),
                                          appends pubkey to the identity doc
    Crypto.AgentKeys.ensure/2             MINTS on :not_found
    Crypto.AgentKeys.signing_context/2    ⭐ LOOKUP ONLY — its own docstring:
                                          "no minting here — that's ensure/2's job"
    Trust.Capability.issue/5, delegate/5
    Trust.writer_authorized?/6            pinned identity → true; OTHERWISE a
                                          chain-verified cert granting write

⛔ **Do not add a new identity mechanism, a new key store, or a new
authorization surface.** If you believe one is needed, **stop and report
that** rather than building it.

## 2. ⛔⛔ THE WHOLE TICKET: REGISTER FROM THE GATE, NOT FROM THE PARSED CONFIG

**The wrong implementation is the NATURAL one** — the parsed config is right
there in `reconcile`, and reads as the obvious place to register. **It is the
hazard.**

**THE THREAT MODEL, because an instruction without its reason gets
"simplified" by the next reader:**
`__processes.json` is **not one trusted file.** The Orchestrator collects it
**recursively from EVERY directory** (orchestrator.ex:553-554). ⇒ If you
register because *an entry exists in the parsed config*, then **anyone who can
write a `__processes.json` anywhere in the tree mints a signing principal.**
**Declaration becomes provisioning.**

**THE CORRECT SEAM — it already exists**, `parse_processes_doc/4`
(orchestrator.ex:578-599):

```elixir
case Commonplace.Trust.authorized_to_execute?(store, doc_uuid) do
  :ok         -> do_parse_processes_doc(...)
  {:error, r} -> :telemetry.execute([:commonplace, :process, :rejected, :trust], ...)
                 []          # contributes NO processes
end
```

Its own comment: *"a `__processes.json` declaration is EXECUTE-AUTHORITY — it
can spawn in-BEAM code or OS commands with `$secret:KEY` env resolution … This
is the only gate on `:sandbox_exec`."*

⇒ ⭐ **Register on the `:ok` branch.** The justification, in one sentence: **if
a declaration is authorised to EXECUTE — OS commands with resolved secrets —
it is authorised to hold an identity, because holding a key is strictly less
power than running arbitrary code with the node's secrets.**
⇒ A failing declaration contributes no processes and therefore **never reaches
registration — by construction, not by a second check.** ⚠️ **That distinction
is the point: a second check can be reordered or forgotten; an unreachable
path cannot.**

## 3. The shape

    Orchestrator, gate passes  →  Presence.Identity.register_agent(config.name, …)
                                  (AgentKeys.ensure — mints once, idempotent)
                               →  Capability.delegate from the node ctx,
                                  scoped to that process's own log doc
    SandboxExecRunner, launch  →  AgentKeys.signing_context(uuid)
                                  ⛔ LOOKUP ONLY — never ensure/2
                               →  threaded into the RedLog writes at
                                  sandbox_exec_runner.ex :149 and :189

⚠️ Those two RedLog sites are **CX-2jfb Tier C sites 4–5** and still use
`RedLog.commit/1`. Convert them to `commit/2` **and inspect the result** — the
same two-defects-per-site rule as Tier A+B (@be28010): unsigned **and**
discarding the refusal are separate failures and fixing one leaves the system
equally blind.

## 4. ⛔ ACCEPTANCE — THE NEGATIVES ARE THE TICKET

1. ⭐ **A declaration that FAILS `authorized_to_execute?` mints NO key.**
   ⛔ **Assert on the SecretStore slot being ABSENT** — `SecretStore.get(…,
   "signing_pub:<uuid>")` returns `:not_found`.
   ⚠️ **DO NOT assert "the process did not start."** *"It didn't run"* and
   *"it has no identity"* are **different claims**, and a test on the first
   **passes for a version that mints the key and then fails for an unrelated
   reason** — green, plausible, and blind to the hazard.
2. ⭐ **A process whose identity is ABSENT at launch returns
   `{:error, :not_found}` and degrades loudly — never mints.**
3. ⛔ **BOTH NEGATIVES SHOWN RED AGAINST THE REGISTER-FROM-PARSED-CONFIG
   VERSION.** Write that version, watch both tests fail, paste the red, revert.
   ⚠️ **Without this the acceptance certifies the hazard** — the tests would
   pass for exactly the implementation this ticket exists to prevent.
4. A registered process's RedLog write **lands** under enforce with a fixture
   anchor, and the commit's `signer_id` is **the process's**, not the node's.
5. `mix compile --warnings-as-errors` rc=0. Named suites, **baselined on main
   first**, one at a time, with both counts:
   - `apps/commonplace/test/commonplace/process`
   - `apps/commonplace/test/commonplace/presence`
   - `apps/commonplace/test/commonplace/crypto`

## 5. ⚠️ WHAT THE FENCE MASKS — read your negatives, don't believe them

- ⛔ **`node_signing_key` is masked to a 0-byte file.** ⇒
  `NodeIdentity.public_key/0` **fails**, so `Trust.config/0` folds in **NO node
  anchor** and **the anchor set is EMPTY in this sandbox.**
- ⇒ ⭐ **EVERY REAL CERT-CHAIN VERIFICATION FAILS IN HERE, WITH
  `:untrusted_root`.** **That is the fence, not a defect.** ⛔ **Do not report
  it as a chain bug, and do not "fix" it.**
- ⇒ **Build and test the registration path against FIXTURE signing contexts and
  fixture anchors.** Report criterion 4's real-chain half as **UNVERIFIED —
  requires a live anchor**, and say so explicitly. It will be run live,
  read-only, outside the fence.
- Also masked: no serve, no store route, no erlang cookie, read-only HOME
  (hex may warn `:eaccess` and still work).
- ⭐ **If something cannot be verified here, SAY SO AND STOP rather than
  approximating.** A negative result the fence could have produced is not a
  result.

## 6. Out of scope

- The other three Tier C sites (`merge_command/handler.ex:318`,
  `bd/frontier/server.ex:162`/`:208`) — **decided separately** (@678f879);
  report anything you notice, fix nothing.
- MCP/CLI per-agent signing — the rest of CX-hk0s, not this brief.
- Any change to the delegation root or the anchor set.
- Any other defect: **report it, don't fix it.**

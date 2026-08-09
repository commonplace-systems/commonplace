# CX-2jfb Tier C — whose identity signs, and what happens when nobody can

2026-08-09. **This is a decision document, not a brief.** The five remaining
`RedLog.commit/1` call sites were held out of the Tier A+B change (@be28010)
because each needs a per-site answer before any code.

⛔ **The census going green is not the goal; the census being TRUE is.**
Threading a node context into all five to make a grep come back clean is
authority-laundering arriving disguised as convenience.

## Two questions per site, not one

boss's addition, and it is load-bearing:

1. **Whose identity signs?**
2. **What happens when that signing context is UNRESOLVABLE?**

⇒ These get answered as one question if you let them, and they are different.
**CX-cj59's third consequence** is that an unreadable node key doesn't only
prevent signing and disable verification — **every component whose error path
is fatal on a refused write becomes a boot failure.** Tier A already produced
one instance: the submitted patch exited from `create_log_doc/2`, which runs
inside `init/1` under `restart: :permanent`, and would have crash-looped the
custody manager. ⇒ **Question 2 is where that class gets caught.**

⭐ The codebase's own answer to question 2, stated eleven lines of comment away
in `AuditDispatcher.offer/2`: **"losing its RECORD must never turn into losing
its ENFORCEMENT."**

---

## Site 1 — `merge_command/handler.ex:318` (`ensure_merge_log_entry/2`)

**⛔ DECISION: DEFER. Do not sign this site yet — it has no production caller.**

`MergeCommand.Handler` is a magenta command handler (moduledoc: *"Singleton
GenServer handling magenta merge commands"*). Measured: **it is started in no
supervision tree.** Every reference outside its own directory is a test
(`enforce_gate_test.exs`, `handler_test.exs`, `merge_log_test.exs`).

- **Whose identity?** The **requester** — whoever published to
  `magenta:commands/{path}/merge`. ⚠️ **The request shape carries no requester
  identity today** (no `principal`/`actor`/`identity` field in the module).
  ⇒ **The principal this site needs does not exist yet.** Signing it as the
  node would assert that the NODE requested a merge, which is false and is
  exactly the laundering this document exists to prevent.
- **When unresolvable?** Not yet applicable.

⚠️ **AND IT IS DOUBLY RIGHT TO DEFER, FOR A REASON THIS DOCUMENT DID NOT
ORIGINALLY CLAIM (plan):** an unsupervised handler **cannot be exercised on
the production path at all**, so any acceptance test for this site would be a
**fixture** test, not a production-caller test. ⇒ **You would be deciding a
signing question you cannot red-test.** That is *"fixtures are not the
production caller"* arriving as a **scheduling** argument rather than a
testing one. **Defer until there is a path that runs.**

⇒ **Blocked on the magenta command envelope carrying a requester identity.**
That is the same missing field as **CX-8fyq** (denial records name the target,
not the actor) at the *request* layer instead of the *audit* layer.
⭐ **Same defect, both ends of the pipe: nothing that crosses a boundary in
this system currently carries who asked.**

### ⇒ AND THE FIELD MUST BE TAGGED, NOT NULLABLE

`nil` cannot carry its own etiology, so *"unknown because the boundary dropped
it"* and *"unknown because nobody asked"* collapse into one value the moment
they are written. Three distinguishable states instead:

    {:principal, id}              — someone asked, and we know who
    {:unknown, :not_propagated}   — ⛔ A BUG REPORT: the boundary dropped it
    {:unknown, :not_applicable}   — a FACT about the site: nobody asked
                                     (e.g. Frontier.Server, acting for itself)

⭐ **That is the enclosure rule applied to a data field instead of a
sentence: A VALUE MUST CARRY WHY IT IS WHAT IT IS.** ⇒ And it makes the
acceptance **mechanically checkable** — you can assert that **no site emits
`:not_propagated`**, which you cannot assert about `nil`.

---

## Sites 2 & 3 — `bd/frontier/server.ex:162` and `:208`

**✅ DECISION: NODE identity. Degrade, do not die.**

`Frontier.Server` is a projection: it subscribes to commit events and
recomputes the ready/blocked frontier. It acts on **no one's** behalf — it is
the node maintaining its own derived view.

- **Whose identity?** The **node**. This is the one case where a node context
  is the honest answer rather than the convenient one: the write genuinely
  originates from node-local machinery with no upstream principal.
- **When unresolvable?** ⛔ **Log loudly and continue with a stale frontier.**
  ⚠️ `:162` is in `handle_info` and `:208` is reached from log-file creation;
  neither may exit. A projection that cannot record its recomputation is
  degraded, **and a ticket tracker whose frontier server crash-loops is worse
  than one whose frontier is stale** — the frontier is advisory, the tracker is
  not.
- ⚠️ **And apply the Tier A lesson at `:208`:** it creates a log doc and then
  adds the schema entry. **Gate the entry on the write landing**, or it
  reproduces the dangling-pointer defect measured on the live serve (five docs
  with zero commits).

---

## Sites 4 & 5 — `process/sandbox_exec_runner.ex:149` and `:189`

**⭐ DECISION: NEITHER NODE NOR USER — this needs the DECLARED PROCESS as a
principal, and that principal does not exist yet. Do not paper it over.**

This is the interesting one, and it is not a mechanical signing fix.

`SandboxExecRunner` is started by the Orchestrator (`orchestrator.ex:475`)
with **`name: config.name`** — the declared-process name from
`__processes.json`. The events it logs are *that process's* output. ⇒ **The
natural principal is the declared process itself.**

- **Whose identity?** The **declared process**. Signing as the node would
  assert the node produced this program's stdout, which is false in exactly
  the way that matters: **the whole point of the sub-agent-identity epic is
  that a non-human component which must sign to act should sign AS ITSELF.**
- ⭐ **This is the smallest live instance of that epic's central question**, on
  a component that already exists and already writes. It is a better rehearsal
  than the Bursar was, because the Bursar could plausibly sign as the node and
  this cannot.
- **When unresolvable?** ⛔ **Log and continue — NEVER exit.** `:189` is in
  `terminate/2`. **A process whose teardown raises loses the very events the
  teardown exists to flush**, and `:149` is a `handle_info` on the port's exit
  status. Neither is a place to die.

### ⛔ AND QUESTION 2 IS A DIFFERENT QUESTION HERE — THIS IS THE PART TO GET RIGHT

boss's caution, and it is the sharpest thing in this document:

> A **node**-signed site fails when the node key is **unreadable** — an error.
> A **process**-signed site has no identity **at first start** — which is the
> NORMAL CASE, not an error condition.

⇒ **The same words, "the signing context is unresolvable," describe a fault at
sites 2–3 and describe Tuesday at sites 4–5.** Answering them with one policy
is how this gets wrong, and it runs **on every sandbox launch.**

**Three candidate policies, and the third is a trap:**
- **DEGRADE** — log, write unsigned, continue. ⇒ Preserves the storm.
- **REFUSE** — don't write the event log at all until an identity exists.
  ⇒ Honest, loses events, and must NOT escalate to refusing to run the
  process (that is CX-cj59's third consequence at a site that starts on
  every launch).
- ⛔ **MINT ON DEMAND** — generate an identity for the process at first start.
  ⚠️ **This is the attractive one and it needs the most scrutiny**, because it
  is exactly the shape of `NodeIdentity.load_or_mint_keypair`'s `:enoent`
  branch — the behaviour that made `--ro-bind /dev/null` load-bearing, since a
  mask by *absence* would have silently minted a fresh node identity. **A
  minting path reached by an absent credential is how a sandbox acquires an
  identity nobody granted it.** If minting is chosen it must be **explicitly
  granted and recorded**, never a fallback on a missing lookup.

⛔⛔ **PROMOTED FROM A WARNING TO A RULE (plan): PROVISIONING MUST NEVER BE A
FALLBACK OF A LOOKUP.** Mint on an **explicit grant, recorded**. A missing
credential is an **ERROR, never a birth.**
⇒ **The failure is silent and self-legitimating:** the sandbox comes up,
signs, and every downstream check passes — **it HAS an identity, it just isn't
one anybody granted.**

⚠️ ⭐ **AND THE INTERACTION THAT MAKES IT WORST EXACTLY HERE: THE FENCE MASKS
CREDENTIALS BY DESIGN, SO THE SANDBOX IS THE ONE CONTEXT WHERE "ABSENT
CREDENTIAL" IS THE NORMAL CASE.** ⇒ **A mint-on-missing path at this site
fires on the HAPPY PATH, every launch** — not on an error branch someone might
notice.

⇒ **Deciding this is a prerequisite for sites 4–5, not an implementation
detail of them.**

⚠️ **AND THIS SITE IS ALREADY IMPLICATED IN THE 08-07 STORM.** The same
Orchestrator → `SandboxExecRunner` → `Sandbox` → `SyncLoop` chain, with
`scope_uuid` nil for `bartleby`, syncs the **workspace root itself**
(`orchestrator.ex:465`) — the doc that took 134,507 refused writes. ⇒ **The
declared process is already the largest unsigned writer we have identified.**
Giving it an identity is not hygiene; it is the fix for the thing that
happened.

---

## Consequent, and it is bigger than this ticket

Three of the five sites are blocked on the same missing thing: **a principal
for a non-human requester** (the magenta merge requester; the declared
process). ⇒ **Tier C is not five signing fixes. It is two signing fixes and
one identity design**, and the identity design is the epic.

⛔ **What must not happen:** signing all five as the node, closing the census,
and recording that the unsigned-writer problem is solved. **The grep would go
green and three of the five claims would be false** — and the resulting
commits would assert, durably and in signed form, that the node did things it
did not do.

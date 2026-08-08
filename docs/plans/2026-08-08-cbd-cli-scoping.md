# `cbd` — scoping, not a build

2026-08-08. Requested by jes as *"a tix command line, cbd as a compat shim."*
**Scoping only.** jes queued the extraction work explicitly ("not necessarily
immediate"), and CX-3mj2 is the item with a live green to protect. This
document is meant to be complete enough that someone can build from it later
without re-deriving today's findings.

---

## 1. The one-line answer: compat in the SURFACE, never in the backend

⛔ **`cbd` must not delegate to `bd`.** A wrapper that shells out to the `bd`
binary would hand jes a CLI that confidently reports a world frozen on
2026-08-05 — the false-negative-on-every-real-ticket failure, productised.

Measured 2026-08-08:

```
tix : 854 issues   (commonplace CubDB, workspace/.commonplace/commits/)
bd  : 798 issues   (Dolt SQL, database "CX", .beads/config.json)
```

The 798 are the migration; the other 56 are every ticket filed since. Two
agents hit this within an hour today; one produced a six-row all-negative
table that was 100% wrong and looked completely convincing.

⭐ **The superset property is what makes this clean: `tix ⊃ bd`.** A
surface-compatible CLI over tix can answer every question `bd` could answer,
plus every question it can't. **Nothing needs to read Dolt.** "Compat" means
*`cbd show CX-wn7z` feels exactly like `bd show CX-wn7z` felt* — same verbs,
same flags, same output shape — while the bytes come from the substrate.

Interim guardrail already shipped: `bin/bd` refuses the reflex and names the
working checks; `CP_BD_ARCHIVE=1` opts into a deliberate archive read. `cbd`
replaces the need for that guardrail; it does not replace the archive.

## 2. ⛔ Store access: route to the serve, NEVER open the store

**This is the constraint that determines the architecture, and it is not
negotiable.**

`cbd` must reach tickets by **calling a running `commonplace serve`**, never
by opening `workspace/.commonplace/commits/` itself. The 2026-08-06 corruption
incident established that *who-can-open-the-file IS the rule*: `commits.lock`
excludes nobody, a second opener's corrupt-open policy silently mints an EMPTY
world, and the resulting store reads as a legitimately empty one. A CLI that
opened the store to answer `cbd list` would be the second opener, on every
invocation, by design.

⇒ **Adopt the refuse-without-serve contract** the MCP escript already has:
with no reachable serve, `cbd` **fails loudly and says so** — it does not fall
back to a local open. Refusing is the feature.

⇒ **Route through `Commonplace.MCP.Tools.BdRoute` (or its moved equivalent),
not through raw `CommitStoreClient`.** BdRoute exists precisely for this: a
single bd query fans out internally into many nested store reads (issue walk,
per-issue meta docs, description docs, custody lookups), and a naive escript
client turns each into a cross-node round-trip — N chances to hang on a
degraded link. BdRoute makes the client thin: **ONE rpc, whole query runs on
the serve**, co-located with the CommitStore. Reuse it; do not reinvent a
client.

⚠️ Note BdRoute's `:local` behaviour — when no serve node is configured it runs
the target function locally, which is right for in-serve and test callers and
**wrong for `cbd`**. `cbd`'s refusal must be decided before that fallback, not
by it.

## 3. Packaging: an escript is viable again — but read CX-a449 first

CX-a449 (**closed** @e1baf4c) fixed the blocker: the flock NIF could not load
inside an escript archive, so the embedded app boot died at `CommitStore.init`.
The fix packages `commonplace/priv/flock_nif.so` into the archive and extracts
it before load, and adds a **named fail-closed refusal** when the NIF is
absent — verified against the built artifact (16,768-byte `.so` present where
the archive previously had no priv entries at all), not against the diff.

Two things to carry forward:

- **Verify the ARTIFACT, not the diff.** Packaging defects are invisible in a
  diff by construction. Whoever builds `cbd` must unzip the escript and look.
- **The failure mode when the NIF is missing must stay named and fail-closed.**
  Its silent-open predecessor is what triggered the 2026-08-06 corruption.

## 4. Four hard requirements, each paid for today

1. ⛔ **Carry a signing context, or refuse loudly.** CX-3nf4 is the precise
   specification of how not to do this: `cli/bd.ex` passes no
   `:signing_context` at `create`/`update`/`close`, so under enforce the gate
   refuses the write **and the CLI prints a freshly minted id anyway**. Follow
   `Commonplace.MCP.Tools.BdWrite.signing_context/1` instead — it resolves a
   real context or returns `{:error, :no_signing_context}` and says so.

2. ⛔ **Never print an id it has not read back.** Every write path re-reads
   the ticket from the store and reports what the *store* returned. This is
   not belt-and-braces; it is the only thing that distinguishes the two
   failure directions observed today:
   - the CLI reported **success on a write that did not land** (CX-3nf4);
   - an erpc reported **failure on a write that did land** — a
     `{:timeout, {GenServer, :call, [CommitStore, …, 5000]}}` whose ticket
     (CX-fbah) exists. **A timeout is not a verdict.** Retrying it blindly
     creates a duplicate, which is worse than a phantom: a phantom announces
     itself the moment someone opens it, a duplicate silently splits work.

   ⇒ Both are the write **reporting on itself rather than on the store**. One
   move fixes both directions.

3. ⛔ **Every negative answer states which store it read.** *"No issue found"*
   is the exact string that cost an afternoon. **The tool that produced it was
   accurate** — it was reading the archive — so the fix is not accuracy, it is
   scope. A negative must carry its scope the way a count carries its
   denominator: *"no issue CX-wn7z in tix (854 issues, workspace store, as of
   <timestamp>)"*. `cbd` is the natural place to make that the default output
   shape rather than a discipline someone remembers.

4. ⛔ **Refuse without a serve** (§2). No local-open fallback, ever.

## 5. Surface

Start from what people actually type, which is a small set:

| `bd` | `cbd` | routes to |
|---|---|---|
| `bd show <id>` | `cbd show <id>` | `Bd.Issue.show/3` (+ `description/3`) |
| `bd ready` | `cbd ready` | `Bd.CLI.ready/2` |
| `bd blocked` | `cbd blocked` | `Bd.CLI.blocked/2` |
| `bd list` | `cbd list` | `Bd.Issue.list/2` |
| `bd create …` | `cbd create …` | `ticket_create` verb |
| `bd update …` | `cbd update …` | `ticket_update` verb |
| `bd close <id>` | `cbd close <id>` | `ticket_close` verb |
| `bd dep add` | `cbd needs <id> <prereq>` | `ticket_add_needs` verb |

⚠️ **Do not port `bd dep add`'s semantics.** Dependencies are `needs` refs on
the ticket, cycle-gated via `ticket_add_needs`; the `/bd/deps.json` blocks
graph is retired and its surfaces raise `RetiredGraphError` on purpose
(CX-hrbn). Surface compatibility stops where it would resurrect a dead model.

Shapes that bite, all hit today — worth encoding in the CLI so nobody hits
them again:

- `needs` entries are `%{"ticket" => id}`, not bare id strings.
- `Workspace.root_uuid/0` returns `{:ok, uuid}`, not a bare uuid.
- `Bd.Issue.list/2` returns `{issue_struct, doc_uuid}` tuples, not maps.
- tix bodies are **write-once** (CX-7smx). `cbd create` should say so at the
  point of use — a body typed in haste cannot be amended later.

## 6. Explicitly out of scope

- **Reading Dolt.** Ever. `bin/bd` + `CP_BD_ARCHIVE=1` remains the archive
  read; the archive is frozen and does not need a new client.
- **Comments**, until CX-xmsd's backfill lands.
- **Migration of anything.** The cutover happened; `cbd` is a client.
- **Replacing the MCP `bd_*` tools.** Those are the agent surface and they
  work. `cbd` is the *human* surface — jes has no working way to check a
  ticket today, and that is the actual gap.

## 7. Open questions (not blockers, but decide before building)

1. **Where does `cbd` live?** `commonplace_cli` alongside the existing escript,
   or its own escript? The existing one already carries the app boot and the
   CX-a449 packaging fix, which argues for reuse.
2. **Whose key signs?** Today MCP writes are NODE-signed (CX-hk0s: no
   per-agent keys yet), so every caller shares one principal. `cbd` inherits
   that. Worth confirming jes is content with node-signed attribution for
   human CLI writes in v1, since it makes `claimed_by` non-discriminating.
3. **Output format.** Straight `bd`-alike text, or `--json` first? Agents
   currently read tickets through MCP, so the human format is the priority —
   but a `--json` mode is cheap now and expensive to retrofit.

# Known Gaps

This document tracks architectural, feature, and quality gaps in commonplace
that are **known** but **deferred**. Anything listed here is known-broken or
known-incomplete. The absence of a gap in the main codebase does NOT imply
it's working — only that nobody has filed it yet.

**Last updated:** 2026-04-10 (post architecture pass — see "Closed" section
for items fixed in that pass).

## How to use this doc

- **Before working around a gap:** skim this file, add a cross-reference from
  your beads issue, and (if relevant) update the gap entry with what you
  learned.
- **When closing a gap:** move the entry to the "Closed" section at the bottom
  with the commit/PR that fixed it and a one-line summary.
- **When discovering a new gap:** add it here *before* shipping the workaround,
  not after. The purpose of this doc is to surface known weaknesses so
  future work knows where the landmines are; an undocumented gap is a
  landmine waiting for the next person.
- **Cross-link from beads:** every gap here should have a beads ticket. If it
  doesn't, file one and add the ID below.

## Index

1. [Architectural gaps](#architectural-gaps)
2. [Deferred phase 2+ view features](#deferred-phase-2-view-features)
3. [Schema / data gaps](#schema--data-gaps)
4. [Test / quality gaps](#test--quality-gaps)
5. [Infrastructure / workflow gaps](#infrastructure--workflow-gaps)
6. [Closed gaps (changelog)](#closed-gaps-changelog)

---

## Architectural gaps

<a id="a1"></a>
### A1. SmartDoc / Orchestrator / push_cyan is half-built

**Status:** load-bearing gap — discovered during Views Pass B (2026-04-09)
**Beads:** CX-18s (architectural reconciliation, low urgency)
**Workaround shipped:** `Commonplace.ViewCompute` (commit a8addbc)

**What's broken:**

- `Commonplace.SmartDoc.handle_blue/2` is called by the Orchestrator's
  dispatch loop as a **stateless module function** — not a `GenServer.call`
  on the SmartDoc's own process. It has no access to the SmartDoc's state
  or to resolved cyan ports.
- `Commonplace.SmartDoc.push_cyan/3` has **zero callers**. It was rewritten
  in Pass B to delegate to `Commonplace.CommandRouter.write/3` as a
  hygiene measure (so if anyone ever calls it, the write is CRDT-safe),
  but no call site exists today.
- `Commonplace.Process.Orchestrator` is **not in the application supervision
  tree** (`apps/commonplace/lib/commonplace/application.ex`). It only runs
  when started explicitly — e.g. by `commonplace serve` or a test. In the
  Phoenix-as-serve dev setup nothing starts it, so the whole SmartDoc path
  is dormant in the running wiki demo.

**What this means:**

The dataflow abstraction implied by `SmartDoc` + `Orchestrator` — "declare
blue inputs and cyan outputs, write `handle_blue`, the system wires
everything up" — is not actually a working end-to-end path. It's a sketch
that was never finished. Anyone who reads the smart_doc.ex + orchestrator.ex
modules and assumes they can write a SmartDoc that reacts to commits and
writes to output docs will hit this wall.

**Why we sidestepped it:**

Views Pass B needed a working reactive computed-view demo. Fixing the
Orchestrator path would have been a multi-day architectural refactor with
unknown risk. Instead, `Commonplace.ViewCompute` ships as a dedicated
GenServer per source-target pair, subscribes to the source's
`blue:UUID` PubSub topic directly, and writes to the target via
`Commonplace.CommandRouter.write/3`. It does not use `SmartDoc` or
`Orchestrator` at all. See `apps/commonplace/lib/commonplace/view_compute.ex`
for the moduledoc's full rationale.

**What the fix looks like:**

When the Orchestrator path does get fixed, the choice is between:

1. **Generalize ViewCompute** into a more general reactive-compute primitive
   that replaces the SmartDoc/Orchestrator abstraction entirely. The vote
   from commonplace-plan (message 1380 on clod-squad, 2026-04-09) is that
   this might be the correct move — the original general abstraction may
   never have been load-bearing for any concrete use case.
2. **Fix the Orchestrator gaps**: add Orchestrator to the supervision tree,
   change the dispatch model so `handle_blue` is a `GenServer.call` on the
   SmartDoc's own process (so it has access to state and resolved ports),
   wire `push_cyan` to the live dispatch path, migrate ViewCompute onto
   this new substrate.

This is **"architectural reconciliation"** work, not tech debt. The
ViewCompute path is not wrong — it's a principled narrowing of the general
dataflow abstraction to the specific "compute a view from inputs" use case.
Deciding between (1) and (2) depends on whether there are other use cases
that need the generality.

---

<a id="a2"></a>
### A2. Signed-identity propagation is a placeholder

**Status:** intentional punt — ships with placeholder identity strings
**Beads:** CX-hoj (per-call signing context for CommitStore) is the
  architectural fix; the placeholders are the interim.

**What's broken:**

Commits produced by the wiki LiveView and by MCP tool invocations all carry
placeholder identity strings:

- Wiki LiveView: `signer_id: "wiki-user@local"`
- MCP InvokeViewAction: `signer_id: "mcp-agent@local"`
- MCP write / cat / other tools: currently unsigned (per CX-rmk MVP scoping)

These placeholders are threaded through the audit trail (magenta events on
`view_actions` topic include them) and preserve the PAYLOAD shape for future
use, but they don't represent real cryptographically-attested identities.
An observer reading the audit stream cannot distinguish "alice clicked edit"
from "bob clicked edit" because both show up as `wiki-user@local`.

**Why this persists:**

1. There's no real session identity in the wiki LiveView — no login, no
   user accounts, no cookie-based auth. Implementing that is a separate
   concern.
2. MCP session identity (the agent's ephemeral keypair) can't be used for
   commit signing without CX-hoj, because the CommitStore signing path
   reads from a global SecretStore slot. Loading an agent's keypair into
   that slot would contaminate concurrent human commits with the agent's
   signature (see CX-hoj description).

**What the fix looks like:**

CX-hoj: thread a `signing_context` (identity UUID + keypair ref) through
`CommitStore.create_commit` / `create_chained_commit` / `CommandRouter`, so
every writer has a well-defined identity that doesn't leak through global
slots. Once that lands, the MCP meta-tool and wiki LiveView handle_event
can populate real signer_ids from their session context instead of the
placeholder strings.

---

<a id="a3"></a>
### A3. CX-hoj: per-call signing context for CommitStore

**Status:** open — see `bd show CX-hoj` for the full design
**Beads:** CX-hoj
**Workaround shipped:** MCP agents commit unsigned; wiki commits use the
  default signing slot (which is nobody in particular in the dev setup)

**Summary:** `CommitStore.maybe_sign_commit/1` reads signing credentials
from a global SecretStore slot. Any concurrent writer (CLI, MCP, wiki
LiveView) using the same process would sign with whatever's currently in
that slot — no per-call isolation, so loading an agent's session keypair
into the slot would cause concurrent human commits to be signed with the
agent's key (worse than unsigned, because the audit trail would
misattribute them).

**Fix:** extend `CommitStore.create_commit` and `create_chained_commit`
with an optional `signing_opts` keyword; `maybe_sign_commit` inspects
those opts first and falls back to the global SecretStore slots only
if nothing's passed. CommandRouter threads its configured context into
every commit call.

Not blocking the Views work but is a prerequisite for meaningful per-user
audit trails.

---

## Deferred phase 2+ view features

<a id="v1"></a>
### V1. Forked views not attached to tree paths — CLOSED 2026-04-10

**Status:** CLOSED — fixed in the architecture pass (2026-04-10).
**Commit:** b3ebf6f
**See:** Closed section below for the full resolution.

<a id="v2"></a>
### V2. JSON-schema args validation on complex view actions

**Status:** explicit punt from Pass A (CX-vaw) + Pass C (CX-c1i) scoping
**Beads:** TBD

**What's incomplete:**

The `<action>` vocabulary supports a hybrid args format per views.md: a
simple colon form (`args="text:string"`) for the 80% case and a JSON-schema
form for complex actions:

```xml
<action name="edit_cell">
  <args format="json-schema">
    {"type":"object","properties":{"cell_id":{"type":"string"}, ...}}
  </args>
</action>
```

Neither format is currently parsed or validated by the ViewRenderer or the
MCP meta-tool. The simple form renders as a literal `args: text:string` hint
beside the button. The JSON-schema form would currently be rendered as a
`<args>` child element with tag `:unknown` (since `args` is not in the
10-element vocabulary — wait, it IS one of the ones ViewXml parses, let me
double-check).

The downstream validation story — "arg inputs come from a form, are parsed
against the schema, and only valid calls dispatch" — is not built.

**Why deferred:** commonplace-plan's explicit guidance during Pass A
scoping: start with no-args actions (edit, history, fork), defer form
rendering and JSON-schema validation to a later pass.

<a id="v3"></a>
### V3. Per-view-focus MCP tool registration (commonplace-plan's pattern 3)

**Status:** explicit future item in views.md; ships as meta-tool in Pass C
**Beads:** TBD

**What's incomplete:**

The MCP meta-tool `invoke_view_action` is a single tool registered at
MCP initialize time. It takes `view_uuid` + `action` and dispatches
generically. This works because Claude Code's MCP client does NOT support
dynamic tool registration post-initialize — you can't add a new tool per
view when the session is running.

A nicer UX would be **per-view-focus tool registration**: the MCP server
picks one "current view" (perhaps based on which view the agent last
cat'd, or a presence-based "where is the agent" signal), walks its
`<action>` declarations, and synthesizes one MCP tool per action with
the correct name, description, and args schema. When the agent switches
focus, the MCP session restarts with the new tool set.

This requires session-restart UX we don't have. Punt until the meta-tool
pattern has proven it's worth the extra complexity.

<a id="v4"></a>
### V4. Staleness UI (parsed but not surfaced)

**Status:** vocabulary exists, renderer doesn't honor it
**Beads:** TBD

**What's incomplete:**

The views.md vocabulary includes `stale` and `stale-relative-to` attributes
on `<view>`:

- `stale="true"` — set by a SmartDoc when it starts recomputing the view
- `stale-relative-to="<commit-id>"` — which input commit triggered the
  staleness

The `ViewRenderer.render_node/2` clause for `:view` calls `stale_indicator/1`
when `stale="true"`, which currently emits a small info banner. But:

1. No SmartDoc currently sets these attributes — `LiveNotesCompute.compute/1`
   emits the view XML without them.
2. The rendering is minimal (a one-line info block). Needs design work to
   fit the wiki UI's style.
3. There's no "clear the stale flag when recompute finishes" path.

<a id="v5"></a>
### V5. Fork-safety lint for computed views

**Status:** blocked on Orchestrator gap (A1)
**Beads:** TBD

**What's incomplete:**

commonplace-plan and I agreed on a pattern (see clod-squad messages 1345
and 1349) where the Orchestrator walks `__processes.json`, computes each
SmartDoc's fork boundary as its containing directory, verifies that output
docrefs resolve within that boundary, and surfaces `fork-safe="false"` +
`fork-boundary="..."` attributes on the produced view when a violation is
detected.

This is achievable from the existing Orchestrator code path but it depends
on the SmartDoc/Orchestrator path being active (see A1), which it
currently isn't. ViewCompute sidesteps the whole path and therefore has no
fork-safety story.

<a id="v6"></a>
### V6. Transclusion resolver for `<include>` — CLOSED 2026-04-10

**Status:** CLOSED — implemented in the architecture pass (2026-04-10).
**Commit:** 6698b3d
**See:** Closed section below for the full resolution.

---

## Schema / data gaps

<a id="s1"></a>
### S1. Beads credential key leaked to git history

**Status:** accepted by jes (2026-04-09, message 1361 on clod-squad)
**Commit:** bf6eab5 (the leak) + 1e9d1a4 (gitignore fix)
**Beads:** TBD

**What happened:**

During Views Pass A commit staging I ran `git add .beads/` which scooped
up `.beads/.beads-credential-key` (a 32-byte local encryption key for the
embedded Dolt database). The `.beads/.gitignore` did not cover it. The
file was pushed to `origin/main` in commit bf6eab5.

After discovering the leak I added the file + related paths to
`.beads/.gitignore` and removed them via `git rm --cached` in commit
1e9d1a4. The credential is still in git history at bf6eab5.

**Decision:** jes chose to accept the leak rather than force-push to
rewrite history. The going-forward discipline is to use targeted file
paths when staging beads updates (never `git add .beads/`). That's
captured in a persistent feedback memory for future sessions.

**What's fragile:**

The broader pattern is that beads writes several files into `.beads/` that
are machine-local and should never be committed, but the upstream
`.beads/.gitignore` doesn't cover all of them. Any future `git add .beads/`
would re-leak similar files if the ignore list is still incomplete.

<a id="s2"></a>
### S2. Beads backup schema drift migration was manual

**Status:** resolved but undocumented as a recovery procedure
**Commit:** 882200c (2026-04-06 manual restore)

**What happened:**

The beads DB schema drifted between April sessions and the backup/restore
flow required manual intervention to bring 102 issues back. The specific
commit message ("bd: restore 102 issues from Apr 6 backup after schema
drift") indicates this was handled at the time but the steps weren't
captured in a runbook.

**What's fragile:**

If the schema drifts again, whoever picks up the problem will have to
re-derive the recovery steps from scratch. Worth writing up as a short
runbook under `docs/runbooks/` when someone hits the next drift.

---

## Test / quality gaps

<a id="t1"></a>
### T1. LiveView integration test coverage is thin

**Status:** 168 view-related tests pass but cover unit-level behavior
**Beads:** TBD

**What's covered:**

- `Commonplace.Document.ViewDetect` — 11 tests on content inspection
- `Commonplace.Document.ViewXml` — 23 tests on XML parsing, Unicode,
  vocabulary coverage
- `CommonplaceWebWeb.ViewRenderer` — 20 tests on element-to-HTML mapping
- `Commonplace.ViewCompute` — 3 tests on reactive compute loop
- `Commonplace.ViewActionDispatch` — 9 tests on dispatch + audit
- `CommonplaceWebWeb.ViewActions` — 8 tests on LiveView adapter
- `Commonplace.MCP.Tools.InvokeViewAction` — 11 tests on meta-tool
  parsing + dispatch

**What's NOT covered:**

- **End-to-end LiveView click tests** using
  `Phoenix.LiveViewTest` / `live/3` — the existing tests exercise
  `ViewActions.dispatch/3` with a fake `Phoenix.LiveView.Socket` struct
  but don't actually render the LiveView, simulate a phx-click, and
  verify the DOM updates. A real LiveView test would catch template/event
  wiring regressions that the unit tests can't.
- **Multi-process concurrency tests** for `ViewCompute` — what happens
  when two sources change within milliseconds of each other? When a
  compute function raises? When the target is forked mid-compute?
- **MCP session integration tests** — the existing InvokeViewAction tests
  use `run_with_content/4` to bypass the store; there's no test that
  drives a real MCP stdio session end-to-end from `initialize` through
  `tools/call`.
- **Cross-layer audit tests** — no test asserts that a wiki LiveView
  click and an MCP tool call with the same action name both produce
  the same audit event shape (modulo the `source` field).

These gaps aren't blockers for shipping but they're where regressions will
hide. Worth adding incrementally as the surface expands.

<a id="t2"></a>
### T2. String.length vs graphemes in Commonplace.Document.Diff — RECLASSIFIED 2026-04-10

**Status:** RECLASSIFIED — the original bug report was incorrect. `String.length/1`
is grapheme-aware in Elixir 1.18.4 (verified directly: it returns 1 for a
ZWJ family emoji, 1 for a flag emoji, 4 for both precomposed and decomposed
"café"). The pre-fix code was already grapheme-correct in practice.
**Commit:** 97cc81f (consistency refactor, not a correctness fix)
**Beads:** CX-r1f (closed with the reclassification noted)
**See:** Closed section below for the correct story.

---

## Infrastructure / workflow gaps

<a id="i1"></a>
### I1. MCP escript rebuild workflow — MITIGATED 2026-04-10

**Status:** MITIGATED via convenience script (2026-04-10).
**Commit:** 2f989e8 — `bin/rebuild-mcp`
**See:** Closed section below for the full resolution.

<a id="i2"></a>
### I2. xmerl code path handling for in-place dev

**Status:** mitigated in `Commonplace.Application.start/2`
**Beads:** N/A

**Summary:**

The Phoenix beam was running before Views Pass 1 added `:xmerl` to
`extra_applications`. On dev-mode startup, the beam's code path is
configured from the `.app` file at boot time; adding `extra_applications`
to mix.exs doesn't retroactively affect a running beam.

During Pass 1 I had to manually `:code.add_patha('/path/to/xmerl/ebin')`
+ `:code.load_file(:xmerl_scan)` via RPC to get the running beam to see
the xmerl modules. Future boots are covered by the `Application.start/2`
callback which now runs `Application.ensure_all_started(:xmerl)`, so this
should not recur — but if someone adds another OTP stdlib dep (`:public_key`,
`:ssh`, etc.) in the future, they'll need to do the same belt-and-braces
ensure-started treatment OR accept that the running beam must be
cold-restarted to pick up the new dep.

<a id="i3"></a>
### I3. Distributed Erlang cookie management is ambient

**Status:** works today by accident
**Beads:** N/A

**Summary:**

RPC-based hot-loading (the pattern used throughout Views Phase 2) relies
on `~/.erlang.cookie` being present and readable by both the running
Phoenix beam and the ephemeral `elixir --sname ...` clients spawned to
run `:rpc.call/4`. If the cookie file is rotated, or if the Phoenix beam
is started with an explicit `-setcookie` flag that doesn't match, RPC
connection will fail silently (`Node.connect/1` returns `false` with no
error).

Nothing fragile here yet, but if future devs start explicitly managing
cookies for security reasons, the hot-reload workflow documented in the
gap entries above will break and need rework.

---

## Closed gaps (changelog)

### 2026-04-10 architecture pass

Dispatched via subagents per boss-clod's "fix the obvious ones" direction
(clod-squad msg #1387). Four closures + one reclassification.

#### I1 — MCP escript rebuild convenience (commit 2f989e8)

Shipped `bin/rebuild-mcp`, a bash wrapper that resolves the project root
from its own location, cds into `apps/commonplace_mcp` (necessary because
`mix escript.build` from the umbrella root fails with "not an umbrella
project"), and runs the build. Works from any cwd. The underlying
constraint (escript is precompiled, doesn't share code path with the
running beam, must be rebuilt after any `apps/commonplace_mcp/lib/` change)
still exists — this just removes the friction.

Usage: `bin/rebuild-mcp` from anywhere.

#### CX-r1f (T2) — Diff cursor-advance (commit 97cc81f) — RECLASSIFIED

**Finding: the original bug report was wrong.** `String.length/1` in
Elixir 1.18.4 IS grapheme-aware. Direct verification:

```
cafe_precomposed length=4 bytes=5
cafe_decomposed  length=4 bytes=6   # combining mark handled correctly
family length=1 bytes=18            # ZWJ emoji, 5 codepoints, 1 grapheme
flag length=1 bytes=8               # regional indicators, 2 codepoints, 1 grapheme
```

The original known-gaps.md T2 entry (and my message to commonplace-plan)
incorrectly claimed `String.length/1` counts codepoints rather than
graphemes. That was misinformation. The pre-fix code was already
grapheme-correct in practice for all inputs exercised by the test suite
AND by the production call sites (MCP write, ViewCompute).

The change that landed in commit 97cc81f is a **consistency improvement**,
not a correctness fix:

- The `:del` and `:eq` branches of `patches_to_edits/1` use `length(chars)`
  directly on the grapheme list from `List.myers_difference/2`.
- The `:ins` branch previously went `chars → Enum.join → String.length`,
  re-deriving the grapheme count by walking the concatenated string.
- `length(chars)` directly on the already-split grapheme list is
  byte-for-byte equivalent today and avoids the second walk.

Four regression tests for combining marks, ZWJ family emoji, regional
indicators, and no-op idempotence are kept as coverage — they pass
against BOTH the pre-change and post-change code.

**commonplace-plan should revert the softening of the Diff contract section**
in views.md. I prompted them (msg #1377 on clod-squad, 2026-04-09) to
soften the grapheme invariant to "codepoint-unit, approximately
grapheme-accurate" based on the incorrect bug claim. The correct statement
is the stronger one: "grapheme-unit offsets, preserved through the
insert/delete ops." I'll notify them separately.

Beads CX-r1f closed with the reclassification reason in its close note.

#### V1 — Forked views attach to tree (commit b3ebf6f)

When a view's `fork` action succeeds via `Commonplace.CommandRouter.fork/2`,
the new UUID is now attached to the workspace root schema under a unique
name `fork-<first 8 chars of the new UUID>`. Jes can navigate to the
forked view in his browser immediately — no more orphan UUIDs.

Shape:

- New `Commonplace.Workspace.root_uuid/0` helper reads the workspace root
  from `<data_dir>/root`. Sibling to the existing `discover/1`.
- `Commonplace.ViewActionDispatch.handle_fork` calls `Workspace.root_uuid/0`
  + `DocBuilder.reconstruct_snapshot` + `Schema.add_file` + a chained
  commit. On any attach failure, returns `{:ok, :tree_mutation, %{...,
  attached: false, attach_error: reason}}` — the fork itself still succeeded
  and the new UUID is surfaced.
- MCP escript bootstrap now propagates the discovered data_dir into its
  own `Application.put_env(:commonplace, :data_dir, ...)` so
  `Workspace.root_uuid/0` called from the escript's process resolves to
  the workspace path rather than the default `"data"` fallback.

Live-verified via stdio JSON-RPC: forking `/wiki/about-views` from an MCP
client produced new UUID `39146da1-b82e-4cab-8566-97cd60f64d74`, attached
as `fork-39146da1` in the root schema. Immediately navigable at
`/wiki/fork-39146da1`.

#### V6 — Transclusion resolver (commit 6698b3d)

New `Commonplace.Document.ViewTransclusion.expand/2` walks a parsed view
tree, finds `<include>` elements with empty/whitespace-only children,
resolves the `from` attribute by walking the root schema, reads the
target doc's content, and splices it in as children of the include.

Features:

- Cycle detection via a visited-set threaded through recursion
- Depth limit (default 4) to bound recursion
- Graceful error handling: resolution failures produce an error-child
  explanation, never raise
- Workspace-relative docref parser: bare filenames, slash-separated
  paths walked entry-by-entry through nested schema docs, leading `/`
  and `wiki/` prefixes stripped
- Plain-text wrap: non-view content becomes `<text format="plain">`
- Idempotent: multiple expansions on the same tree converge because
  includes with substantive children are preserved

Wired into `CommonplaceWebWeb.ViewRenderer.render_view/2` between parse
and `render_node` — hand-authored static views get transclusion for free.

Out of scope (phase 3+ if needed): commit-pinning via the `commit`
attribute, `../` navigation, `!`/`~` docref prefixes, DocRef
`path:uuid@cid` format, format conversion between view XML and other
text types.

8 new tests cover the resolver; all 124 commonplace document tests
green; all 20 view renderer tests green.

### Changelog template

When closing future gaps, use this format:

```
#### <GAP-ID> — <short title> (commit <SHA>)

<one-paragraph description of what was fixed and why the fix was obvious
(or why the original framing was wrong, in the case of reclassification)>

<bullets on scope + verification>
```


---

## Maintenance

This doc is meant to be **edited in place** as gaps open and close. Treat
it like a living README for the project's known weaknesses. If it goes
stale, the next person to discover a gap won't trust it and will build
their own mental model from scratch, which defeats the purpose.

When adding a new gap, follow the existing structure: status line, beads
reference, workaround (if any), and enough detail that someone unfamiliar
with the context can understand what's broken and why.

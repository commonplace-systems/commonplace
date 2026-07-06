# CX-o1l9 spec — Black M1: query verbs, pattern-scoped subscription, emit_red

Author: commonplace (Fable design/review; Sonnet implements). Design
authority: commonplace-plan `docs/plans/2026-07-06-black-channel-brief.md`
— Option 1 (composition discipline) + jes's two extensions (§4.5) + the
SETTLED forks: F2 (Black is a PEER in the Elixir-DSL-in-documents — one
rainbow DSL, no second query language), F4 (no take/consume — that's
green's), F5 (indexes deferred; compute scans fine at current scale).

## 0. The one-sentence model

Black is not a subsystem: a black query is Elixir code in an
execute-gated code doc, given three new stdlib capabilities — find docs
by pattern (`select`), read any doc's canonical structure (`json`/`xml`),
and emit red (`emit_red`) — plus one new substrate mechanism, compute
docs whose SOURCE is a pattern instead of an enumerated UUID list.

## 1. Piece (i) — `Commonplace.Black` query stdlib (one-shot verbs)

New module `Commonplace.Black` (apps/commonplace), the query-verb half of
the Compute stdlib (peer of `Commonplace.Compute`; same "callable from
user code docs" posture):

- `select(root_uuid, pattern, opts \\ [])` → `[%{path: String.t(),
  uuid: String.t()}]`. Walks the schema tree from `root_uuid` (via
  `Tree.Schema.entries/1` + `DocBuilder` reconstruction, read-only,
  `opts[:store]` default CommitStoreClient), matching slash-separated
  glob patterns: `*` (one segment), `**` (any depth), `?`, `[abc]` —
  fnmatch semantics, compile to regex per segment. Deterministic
  DFS order (schema entry order). Depth cap `opts[:max_depth]`
  (default 32) and a match cap `opts[:limit]` (default 10_000) — walks
  must be bounded (this is user code running server-side).
  Check for an existing glob matcher before writing one (presence
  honorific globs exist somewhere in the codebase — reuse if it fits,
  extract-and-share if close).
- `json(uuid, opts \\ [])` → `{:ok, decoded_map_or_list} | {:error, _}`
  — the doc's canonical JSON (delegate to
  `Commonplace.GitBridge.CanonicalJson`, then `Jason.decode`). This is
  jes's structured-path extension made real WITHOUT a path language:
  canonical render gives a stable structure; predicates over it are
  plain Elixir (`get_in/2`, pattern matching). No JSONPath/XPath
  engine in M1 — the declarative path-pattern subset is explicitly a
  possible LATER convenience layer (brief F2 last sentence).
- `xml(uuid, opts \\ [])` → `{:ok, xml_string} | {:error, _}` — same
  via `CanonicalXml`.

Receipts worked example from the brief, as a doctest/test:
`select(root, "invoices/**/*.json") |> Enum.filter(fn m -> {:ok, inv} =
json(m.uuid); inv["status"] == "open" end)` — "open invoices" in two
lines of rainbow DSL, zero new language.

## 2. Piece (ii) — pattern-scoped subscription (the new substrate)

New GenServer `Commonplace.Black.PatternCompute` (sibling of
`ViewCompute`, NOT a modification of it — ViewCompute's single-source
contract stays untouched):

- Opts: `root_uuid`, `pattern`, `target_uuid`, and exactly one of
  `compute_fn` / `code_uuid` (mirror ViewCompute's init validation).
  `compute_fn` shape: `(matches :: [%{path, uuid}], ctx :: map) ->
  new_target_content :: String.t()` — it receives the CURRENT match
  list; reading matched docs' content is the compute's own job via
  `Black.json/xml` (keeps the engine thin).
- Mechanism: on init, evaluate the match set (`Black.select/3`) AND
  collect the uuids of every directory schema doc visited during the
  walk (`select` gains an internal `:with_dirs` mode returning both).
  Subscribe (blue/commits topics — match ViewCompute's choice) to:
  every matched doc + every visited dir schema. On a dir-schema
  commit: re-evaluate the match set, diff, subscribe new matches +
  newly-visible dirs, unsubscribe dropped ones, recompute. On a
  matched-doc commit: recompute. THE pin that makes this black and not
  just multi-source: a doc created AFTER init that matches the pattern
  triggers recomputation without any re-registration.
- Debounce identical to ViewCompute if it has one; write the target
  via the same `CommandRouter.write/3` call site ViewCompute uses
  (dataflow-is-the-only-verb; the write funnel's stable hand + the
  qat5.3 gate both apply for free).
- Loop safety: refuse (init error) a `target_uuid` that matches the
  pattern under `root_uuid` — the one obvious self-retrigger cycle;
  deeper cycle detection is out of scope (note it in the moduledoc).
- Supervision: a `Commonplace.Black.PatternComputeSupervisor`
  (DynamicSupervisor + ensure_started idempotency), modeled on
  `ChatViewComputeSupervisor`.

## 3. Piece (iii) — `emit_red` (author-facing red, tiny)

`Commonplace.Black.emit_red(doc_uuid, event_payload)` — thin wrapper
over the substrate red broadcast (`Commonplace.Dataflow.PubSub.
broadcast_red/2` — verify exact name/arity in dataflow/pub_sub.ex).
Payload constraint: a map, tagged by the wrapper as
`{:black, :signal, %{source: <emitting context if available>, payload:
payload}}` so red subscribers can distinguish author-emitted signals
from substrate events. No new trust surface: the only path to calling
it from doc code is inside an execute-gated compute (Gate B), which is
exactly the brief's "trust story pre-built".

With (ii) + (iii), the §4.5 output-edge trigger family ("when pattern
matches → run blue compute / emit red") is pure composition — a
PatternCompute whose compute_fn calls `emit_red` — and needs NO
dedicated trigger machinery. Say so in `Commonplace.Black`'s moduledoc;
that moduledoc is also where the black = sensor / green = actuator
split (brief §6) gets its code-side pointer.

## 4. Out of scope (M1)

- Ephemeral/scratch query docs (F3 — revisit on friction).
- Secondary indexes (F5 — deferred until measured).
- JSONPath/XPath string predicates (F2 residue — later convenience).
- Green verbs (bursar acquire/release author forms — CX-vfau).
- Any MCP tool exposure (a later, thin layer once verbs exist).
- Cross-doc history joins (CX-6sf2.7's hardest ask) — commit-log
  queries are a follow-up verb family; M1 is current-state only.

## 5. Test pins

1. `select/3`: glob semantics per segment (`*` vs `**` vs literal),
   deterministic order, depth/limit caps enforced, empty on no-match.
2. `json/2` + `xml/2` round canonical renders for a map doc and an
   xml doc (reuse GitBridge canonical test fixtures/patterns).
3. Receipts example end-to-end: seeded invoice tree → open-invoice
   filter returns exactly the open ones.
4. PatternCompute: (a) matched-doc edit recomputes target; (b) a NEW
   doc committed under a matching path after init triggers subscribe +
   recompute (THE pin); (c) non-matching doc changes do not recompute;
   (d) removed entry drops from the match set; (e) target-matches-
   pattern init refusal.
5. `emit_red/2`: a red subscriber on the doc's topic receives the
   tagged signal.
6. Full corpus green; `mix compile --warnings-as-errors` clean.

## 6. Effort and constraints

M (one stdlib module + one GenServer + supervisor + tests). DO NOT
SPAWN SUBAGENTS. Don't refactor ViewCompute. Don't touch chat/web/
login code (a parallel build owns those files — if you think you need
to edit anything under apps/commonplace_web/ or lib/commonplace/chat/,
STOP and flag it in your report instead). Bounded walks, no unbounded
recursion. Style: rich WHY-moduledocs, CX-o1l9 references.

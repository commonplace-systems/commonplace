# S1 build brief: binary-file sync handling + undeclared-scope refusal — ONE round, they land together

> Plan's ruling (msg 11155): CX-g8r1 is RELEASED from its ordering constraint
> CONDITIONALLY — the condition is the refusal half of this brief. The crash
> was the accidental protector (it stopped 123 credential archives once);
> this round replaces it with a deliberate protector before removing it.
> ⛔ The two halves land in ONE commit series in this round — never the
> crash-fix alone.

## ⛔ Escape hatch, up front

Stop and REPORT instead of building if:
- A binary/blob content type turns out to already half-exist anywhere in
  ContentType/Yelixer (grep before assuming) — that changes the design
  space and the round.
- The refusal half seems to require touching the SERVE's own sync-agent
  boot path. The refusal is scoped to the PROTO-CHIT emit path only (cells);
  the live serve's sync must be bit-for-bit unaffected — if you cannot
  scope it there, report.
- ⚠️ Sandbox: trust anchors resolve empty in here; sync tests use fixture
  signing contexts and tmp stores like the existing ones. Any
  :untrusted_root you see is the fence.

## Half A — the crash (CX-g8r1)

`Watcher.do_apply_create_file` (watcher.ex ~:248) hardcodes
`ContentType.create(doc, :text, name)` + `insert_text` of raw bytes;
`ContentType`'s `@valid_types` has NO binary type, and non-UTF-8 content
crashes `String.length` inside `Yelixer.Item.new/6` — aborting the ENTIRE
sync pass (the live stack is in CX-g8r1's ticket).

PROPERTY (deliberately not full binary storage — that needs a content-type
design this round must not improvise):
1. A file whose content is not valid UTF-8 (`String.valid?/1`, not a
   heuristic) NEVER crashes or aborts the pass.
2. It becomes a NAMED PER-FILE REFUSAL: logged loudly with path + reason,
   counted, and surfaced in the pass's outcome so
   LANDED ∪ REFUSED == files-encountered (denominator built from what
   ARRIVED). The same guard covers `apply_modify`'s new_content path — a
   text file REPLACED by binary content must refuse the modify, not crash.
3. Refused files leave the schema untouched (no entry minted for a refused
   create; existing entry unchanged on a refused modify).
4. Full binary-fidelity storage is OUT of this round, pointed at the
   manifest/content-type design (say so in the commit message).

## Half B — undeclared scope refuses (plan's ruling ①)

Today the emit path falls back to the four-name default excludes when the
operator declares nothing — a cell without `PROTO_CHIT_SYNC_EXCLUDES` gets
denylist-by-default with (after Half A) no crash left to save it.
Absence is not consent (the CX-1ern posture, applied to sync scope).

PROPERTY:
1. A proto-chit emit with NO operator scope declaration REFUSES the
   emission loudly — the error names the knob(s) and how to declare —
   git itself never blocked (the shim's contract; the refusal WALs like
   any failed emission, and with CX-z0sa's fix the WAL keys on the missing
   confirmation regardless).
2. Declaration forms: `PROTO_CHIT_SYNC_EXCLUDES` set (even to explicitly
   declare additions), or repeated `--sync-exclude`, or an explicit
   declare-empty form you choose (name it in the error message). The
   UN-DROPPABLE defaults stay appended to any declaration exactly as today
   — they are protections, not a declaration.
3. The pilot/ceremony (which declares via env) is behaviorally unchanged.
4. Scope: the CLI/emit path (`cli/proto_chit.ex` + `ProtoChit.emit` opts).
   `Watcher` keeps accepting `exclude_names` as a plain opt — library
   callers and the serve are untouched.

## Tests (red-first, both halves)

- A: repo with one binary file among text files → unmodified code CRASHES
  the pass (record it) → after: pass completes, text files landed, binary
  file a named refusal, schema clean of it. Modify-to-binary variant.
  Control: all-text repo unchanged behavior.
- B: emit with no declaration → unmodified code proceeds with defaults
  (record it) → after: refuses naming the knobs; WAL records the intent;
  real git still ran. With declaration → proceeds. Declare-empty form →
  proceeds with defaults-only.
- Shim-level tests follow the existing fake-emitter harness if the refusal
  surfaces new emitter output the shim must pass through (it should need
  nothing — verify, don't assume).

## Gates

- Watcher/sync test files + `cli_proto_chit_shim_test.exs` + full core
  suite `mix test apps/commonplace/test` (sync is the shared seam) — counts
  reported; the cli app suite too (`mix test apps/commonplace_cli/test`).
- `mix compile --warnings-as-errors` clean. Tmp stores only.

## Deliverable

Work left UNCOMMITTED for the operator to land (the sandbox cannot write
.git). Report: red-first verbatim for BOTH halves, the grep result from the
escape-hatch check, test counts, deviations.

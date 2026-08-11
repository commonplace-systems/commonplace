# S1b build brief: undeclared sync scope REFUSES — the protector half, landing first

> SPLIT from S1 (2026-08-11 ~05:15Z): S1's escape hatch fired — Sol's
> pre-build grep found a half-implemented binary path already in Yelixer
> (Item {:binary,_} content, Encoding content ref 3, no ContentType
> envelope), which changes Half A's design space and sends it to plan
> (finish the real :binary type vs the skip-loudly floor). THIS brief is
> Half B alone. Plan's binding order permits it: "the pair lands together
> or SCOPE-FIRST, never crash-fix-first" — this IS scope-first, and
> CX-g8r1's crash fix stays blocked until Half A's design ruling.

## ⛔ Escape hatch, up front

Stop and REPORT if the refusal cannot be scoped to the proto-chit emit path
(cli/proto_chit.ex + ProtoChit.emit opts) without touching the serve's
sync-agent boot or Watcher's library behavior. Watcher keeps accepting
`exclude_names` as a plain opt; the serve is bit-for-bit unaffected.

## The property (unchanged from S1's Half B)

1. A proto-chit emit with NO operator scope declaration REFUSES the
   emission loudly — the error names the knob(s) and how to declare — and
   git is never blocked (the refusal flows through the ordinary failed-
   emission path: WAL fallback + F1 loudness; the CX-z0sa confirmation
   contract already covers it since no tap-fired token is printed).
2. Declaration forms: `PROTO_CHIT_SYNC_EXCLUDES` set (a SET-BUT-EMPTY value
   is the explicit defaults-only declaration), or repeated `--sync-exclude`
   flags, or an explicit declare-empty flag. Name every form in the refusal
   message. The un-droppable defaults stay appended to any declaration
   exactly as today — protections, not a declaration.
3. The pilot/ceremony (declares via env) is behaviorally unchanged.

Note: S1's run drafted a shim-side mechanism before restoring (set-but-empty
env → `--declare-empty-sync-excludes` flag). You may rediscover or improve
on it; it is prior art, not a prescription.

## Tests (red-first)

- Emit with the env UNSET and no flags → unmodified code proceeds with
  defaults (record it) → after: refuses, naming the declaration forms; the
  WAL records the intent; real git still ran.
- Env SET-but-empty → proceeds, defaults-only.
- Env set with names → proceeds, defaults + names (today's behavior).
- Shim-level tests in the existing fake-emitter harness for whatever shim
  changes you make; the CX-z0sa confirmation tests keep passing.

## Gates

- cli app suite + shim test file + core proto-chit tests + full core suite;
  counts reported. `mix compile --warnings-as-errors` clean. Tmp stores.

## Deliverable

Work left UNCOMMITTED for the operator to land. Report: red-first verbatim,
test counts, deviations.

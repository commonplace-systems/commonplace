# CX-z0sa build brief: shim WAL decision keys on POSITIVE persist confirmation, never exit status

> BUFFER ITEM (jes's Sol-warm directive ③) — dispatch after the measurement
> window closes; the work itself needs no serve and no umbrella runs.

## ⛔ Escape hatch, up front

Stop and REPORT instead of building if:
- The fix seems to require changes beyond `tools/proto-chit/bin/git` (the
  shim) and its test file `apps/commonplace_cli/test/commonplace/cli_proto_chit_shim_test.exs`.
  The emitter side needs NO change — verify this yourself first (see "the
  token" below) and report if that verification fails.
- Preserving the F1 loudness contract (every emitter line still reaches the
  invoking user's stderr, unchanged, in order) seems impossible without
  bash-isms — the shim is `#!/bin/sh` POSIX and must stay POSIX.

## The defect (CX-z0sa, measured live 2026-08-10)

The shim runs the emitter and keys its WAL fallback on exit status
(`if [ "$emit_status" -ne 0 ]`, ~line 73). A SIGTERMed BEAM shuts down
gracefully and EXITS 0, so a killed emission reads as success: no WAL entry,
no warning, and real git proceeds — a git mutation with no event and no
envelope, invisible to F1's loud line forever. Proven live: emitter killed
mid-sync at 21:42Z, log shows "[notice] SIGTERM received - shutting down",
reflog shows real git ran at 21:42:51, state dir never created, WAL count
unchanged.

## The token (verify before building)

`apps/commonplace_cli/lib/commonplace/cli/proto_chit.ex:49` prints
`proto-chit: tap fired <event_ref>` to stderr ONLY inside the success branch
— after `persist_event` has landed the event. Confirm by reading that
`with` block: the token is unreachable on any failure path. That line IS the
positive confirmation; the emitter does not change.

## The property

1. The shim treats an emitter invocation as successful ONLY if its captured
   output contains a line matching `^proto-chit: tap fired ` — regardless of
   exit status. Exit 0 without the token ⇒ WAL fallback runs (with a failure
   tag naming the condition, e.g. `emitter-exit-0-unconfirmed`).
2. Nonzero exit keeps today's behavior (WAL fallback), token or not — a
   nonzero exit after a printed token is suspicious and gets the WAL entry
   plus the existing loud path (fail toward recording).
3. F1 loudness preserved: every line the emitter writes still reaches the
   caller's stderr, in order. (POSIX-safe shape: capture to a temp file,
   `cat` it to stderr after the emitter exits, grep the file for the token.
   No pipes around the emitter — `sh` has no pipefail. Clean up the temp
   file on every path.)
4. Nothing may block or fail git: every new step guarded, falls through —
   the shim's existing contract, stated in its own comments.

## Tests (red-first, in the existing harness)

The test file already drives the shim with fake shell-script emitters —
follow that pattern. All three below, with the RED result recorded on the
unmodified shim before the fix:

- RED-FIRST: fake emitter prints boot-ish noise then `exit 0` WITHOUT the
  token (the graceful-SIGTERM shape) → assert a WAL entry EXISTS at
  `$PROTO_CHIT_STATE_DIR/events.wal.ndjson` and real git still ran.
  (Currently: no WAL entry — that is the defect.)
- CONTROL: fake emitter prints `proto-chit: tap fired abc123` then exit 0 →
  NO new WAL entry, git ran.
- REGRESSION: fake emitter exits 3 → WAL entry (today's behavior preserved).
- LOUDNESS: fake emitter writes two distinct marker lines → both appear in
  the shim's stderr output, in order.

## Gates

- The shim test file, then the full commonplace_cli app suite
  (`mix test apps/commonplace_cli/test` from the worktree root — check the
  count is nonzero; a zero-test run is the umbrella path-drop, VOID).
- Shellcheck-clean if shellcheck is available; POSIX sh throughout.
- No stores opened outside tmp dirs; no serve interaction.

## Deliverable

One commit on the branch you are given, not pushed. Report: red-first
outputs verbatim, test counts, the token-placement verification result, any
deviation.

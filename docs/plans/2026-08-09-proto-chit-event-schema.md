# Proto-chit punctuation event schema

Status: **step 1a review contract**  
Version: `proto-chit-event/v1`  
Date: 2026-08-09

This document is the contract that true chit will consume. It is complete
without reference to the PATH shim or its implementation. Proto-chit is an
onramp: these records are signed substrate facts and real tree pins, but this
document does **not** claim that work records accrue natively or that git has
ceased to be authoritative.

## Canonical event shape

An event is a JSON object with exactly these six required keys. JSON object
member order has no meaning.

```json
{
  "verb": "commit",
  "author-principal": "8d63b9f2-…",
  "message": "Explain the boundary",
  "proto-pin": {
    "format": "commonplace-reflog-path-pin/v1",
    "checkpoint": {
      "doc": "5dc58ff7-…",
      "commit": "64 lowercase hex characters"
    },
    "entries": {
      "lib/example.ex": {
        "doc": "bc14a777-…",
        "commit": "64 lowercase hex characters"
      }
    }
  },
  "predecessor-ref": {
    "branch": "main",
    "event-refs": ["64 lowercase hex characters"]
  },
  "git-sha": "40 or 64 lowercase hex characters, or null"
}
```

The enclosing substrate commit is the event's durable identity and signature
carrier. It is deliberately not duplicated as a seventh self-referential
field in the event body.

## Fields

| Field | Type and constraints | Source | It is **not** |
|---|---|---|---|
| `verb` | Required string enum: `commit`, `merge`, `branch`, or `rewrite`. | Classification of the intercepted git argv before real git executes. `commit --amend` is `rewrite`; `merge`/`pull` is `merge`; ref/checkout operations are `branch`; history-changing rewrite operations are `rewrite`. | An arbitrary git subcommand, a free-form action name, or an event identity. |
| `author-principal` | Required non-empty string naming a Commonplace principal. | `SigningContext.identity_uuid` used for the gated event-log write. The enclosing commit's `signer_id` and Ed25519 signature prove which key wrote for this principal. | `user.name`, `GIT_AUTHOR_NAME`, an inferred OS account, a git author string, or an unsigned claim. |
| `message` | Required UTF-8 string; empty is permitted when git supplied no human message. | First explicit `-m`/`--message` value when present; otherwise the human-readable operands of the tapped command. | Event identity, a canonical serialization of argv, or permission to discard the original argv from a WAL record. |
| `proto-pin` | Required `commonplace-reflog-path-pin/v1` object on a landed event. `checkpoint.doc` is the reflog `__snapshot` document UUID; `checkpoint.commit` is its 32-byte commit id encoded as 64 lowercase hex characters. `entries` maps checkout-relative POSIX paths to `{doc, commit}` pairs, where `doc` is a document UUID and `commit` is a 32-byte id encoded as 64 lowercase hex characters. | Cut only after the synchronous disk→CRDT sync pass returns and a second scan proves no changes remain. The pin is the real reflog checkpoint resolved through `Commonplace.Reflog.Restore`; the checkpoint and sync writes use the same explicit signing context and ordinary gated write path. | A git tree id, a git sha, a content-hash placeholder, an eventually-consistent/torn scan, or a pin reconstructed after the event silently. |
| `predecessor-ref` | Required object: `{branch: string, event-refs: [hex]}`. `event-refs` has zero entries for a first punctuation, one for an ordinary per-branch successor, and up to two for a merge when both branch tips are known. Each ref names the enclosing substrate commit of an earlier event. | A worktree-local predecessor map, advanced only after the signed event lands. The current branch contributes its last event ref; a named merge source contributes the second. | A timestamp ordering, a git parent sha, a branch name by itself, or proof that an absent merge parent never existed. |
| `git-sha` | Required nullable string. Non-null values are the 40- or 64-hex object name returned by `git rev-parse --verify HEAD` immediately before real git executes. | Read from the disposable local git scaffolding at tap time. `null` means there was no resolvable `HEAD` (for example, the first commit). | Event identity, a proto-pin, a predecessor reference, authority, or the resulting sha of an operation that has not executed yet. **Annotation only.** |

## Pin-cut and write ordering

For a landed event the required order is:

1. synchronously import the checkout's source state through the signed sync
   path, excluding `.git`, `.commonplace`, `_build`, and `deps`;
2. scan again and refuse emission if any disk/CRDT changes remain;
3. create and resolve the signed reflog checkpoint;
4. append this six-field object to the red event log using the principal's
   `SigningContext` through `CommitStoreClient` and the local trust gate;
5. after that write lands, advance the worktree-local branch predecessor to
   the enclosing event-log commit id;
6. execute real git. Event failure never blocks step 6.

The git operation occurs after the event by design. Therefore `git-sha` is an
observation of pre-exec scaffolding, never the event's identity and never a
claim about the resulting commit.

## Unsigned-path refusal and WAL

There is no raw/unsigned substrate fallback. Missing credentials, an
unreachable store/serve, a trust-gate rejection, an incomplete sync, or a pin
failure makes emission fail. The shim then appends and `fsync`s one JSON line
to:

`$PROTO_CHIT_STATE_DIR/events.wal.ndjson`

If `PROTO_CHIT_STATE_DIR` is unset, the worktree-local default is
`tools/proto-chit/state/`; no WAL path outside the worktree is implied or
installed. A WAL row is an explicitly unsigned **intent envelope**, not a
landed event. It contains:

- `status: "pending"` and `replay-grade: "pin-cut-at-replay"`;
- the six-field candidate under `event`, with `proto-pin: null`;
- the original git argv and failure reason;
- SHA-256 content hashes for source files, excluding the same housekeeping
  paths as sync; and
- its recording time.

A pending row is not allowed to be quiet. Whenever the WAL exists and is
non-empty, **every** shim invocation — read verbs included, so `git status`
carries it — prints exactly one line to stderr before handing off to real git:

`proto-chit: 14 pending unsigned envelopes, oldest 3d`

The count is the WAL's line count and the age is derived from the first row's
`recorded-at`, in a single humane unit (`37s`, `12m`, `5h`, `3d`); a row the
shim cannot parse still reports the count with age `unknown`. The line is
advisory only: it never touches stdout, never changes git's exit status, and
any failure inside the report falls through to the git invocation. Without it,
a checkout with broken credentials lands zero events for weeks while feeling
fully functional.

Replay must reacquire a real `SigningContext`, rerun the gated sync, cut the
real reflog-format pin, and write a newly signed event. It must never copy the
unsigned WAL candidate directly into the store. Content addressing can make
the replayed content pin equivalent when the source hashes still match; the
grade permanently records that the cut's timing was later.

## Explicit tap surface

The v1 shim taps these top-level commands:

- `commit` (`--amend` classifies as `rewrite`), `cherry-pick`, `revert`;
- `merge`, `pull`;
- `branch`, `checkout`, `switch`, `tag`, `worktree`;
- `rebase`, `reset`, `filter-branch`, `replace`, `update-ref`, `notes`,
  `bisect`, `reflog`, and `stash`.

Read-only commands pass directly to real git. The following write surfaces are
explicitly **untapped** because they do not declare a history/ref punctuation
boundary in v1: index/worktree preparation (`add`, `rm`, `mv`, `restore`,
`clean`), repository configuration (`config`, `remote`), object maintenance
(`gc`, `repack`, `prune`), transport-only operations (`fetch`, `push`), and
plumbing commands other than the explicitly tapped ref mutators above. Calling
an untapped command through an alias or shell script can hide a rewrite; pilot
usage therefore forbids aliases that expand to history/ref mutations.

## Open questions for pins-from-spec review

1. **Post-exec git correlation.** The ruled tap order cannot include a new
   commit's resulting sha in the pre-exec event. Should step 1b add a separate
   signed correlation annotation after git returns, or is the pre-exec `HEAD`
   annotation sufficient?
2. **Detached HEAD predecessor namespace.** v1 uses the literal branch
   `DETACHED`, so independent detached sequences share one local predecessor
   lane. Should true chit key detached lanes by the observed git sha instead?
3. **Merge source resolution.** v1 records a second predecessor only when the
   merge operand names a branch present in the local predecessor map. How
   should octopus merges, remote-tracking names, and raw-sha merge operands be
   represented without guessing?
4. **Message files and editors.** v1 extracts direct `-m`/`--message` values;
   `-F` files and editor-produced commit messages are not available before git
   runs. Should the later correlation annotation carry git's final message?
5. **Event-log partitioning.** The pilot receives one configured event-log
   UUID. The stable rule for one-log-per-checkout versus one-log-per-principal
   remains deliberately unsettled.


# Proto-chit punctuation event schema

Status: **step 1b review contract**
Version: `proto-chit-event/v1`  
Date: 2026-08-09

This document is the contract that true chit will consume. It is complete
without reference to the PATH shim or its implementation. Proto-chit is an
onramp: these records are signed substrate facts and real tree pins, but this
document does **not** claim that work records accrue natively or that git has
ceased to be authoritative.

## Canonical main-event shape

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
    },
    "exclusions": [
      {"path": "priv/archive.bin", "reason": "excluded-binary"}
    ]
  },
  "predecessor-ref": {
    "branch": "main",
    "event-refs": ["64 lowercase hex characters"],
    "unresolved": []
  },
  "git-sha": "40 or 64 lowercase hex characters, or null"
}
```

The enclosing substrate commit is the event's durable identity and signature
carrier. It is deliberately not duplicated as a seventh self-referential
field in the event body.

## Canonical post-exec annotation shape

Every landed main event is followed, after real git returns, by a separate
signed event in the same RedLog:

```json
{
  "kind": "post-exec",
  "author-principal": "8d63b9f2-…",
  "main-event-ref": "64 lowercase hex characters",
  "resulting-git-sha": "40 or 64 lowercase hex characters, or null",
  "exit-status": 0,
  "message": "The final commit message"
}
```

`main-event-ref` is the enclosing substrate commit id of the correlated main
event. The annotation uses the same `SigningContext` principal, but its own
enclosing commit is its signature carrier. `resulting-git-sha` is observed with
`git rev-parse --verify HEAD` after git returns. `exit-status` is real git's
non-negative process exit status. For `commit`, `cherry-pick`, and `revert`, a
successful operation's `message` is read back from the resulting commit;
otherwise it uses the main event's argv-derived human message.

The annotation does not contain a proto-pin or predecessor ref. It performs no
sync, cuts no checkpoint, and never advances the worktree-local predecessor
map: it witnesses the main event rather than becoming the next chain-of-record
node.

## Fields

| Field | Type and constraints | Source | It is **not** |
|---|---|---|---|
| `verb` | Required string enum: `commit`, `merge`, `branch`, or `rewrite`. | Classification of the intercepted git argv before real git executes. `commit --amend` is `rewrite`; `merge`/`pull` is `merge`; ref/checkout operations are `branch`; history-changing rewrite operations are `rewrite`. | An arbitrary git subcommand, a free-form action name, or an event identity. |
| `author-principal` | Required non-empty string naming a Commonplace principal. | `SigningContext.identity_uuid` used for the gated event-log write. The enclosing commit's `signer_id` and Ed25519 signature prove which key wrote for this principal. | `user.name`, `GIT_AUTHOR_NAME`, an inferred OS account, a git author string, or an unsigned claim. |
| `message` | Required UTF-8 string; empty is permitted when git supplied no human message. | First explicit `-m`/`--message` value when present; otherwise the human-readable operands of the tapped command. | Event identity, a canonical serialization of argv, or permission to discard the original argv from a WAL record. |
| `proto-pin` | Required `commonplace-reflog-path-pin/v1` object on a landed event. `checkpoint.doc` is the reflog `__snapshot` document UUID; `checkpoint.commit` is its 32-byte commit id encoded as 64 lowercase hex characters. `entries` maps checkout-relative POSIX paths to `{doc, commit}` pairs, where `doc` is a document UUID and `commit` is a 32-byte id encoded as 64 lowercase hex characters. When the sync pass skips files, `exclusions` is a path-sorted list of `{path, reason}` objects; binary files use reason `excluded-binary`. The field is absent when the list is empty, preserving all-text pins exactly. This is an additive v1 field, so the format remains `commonplace-reflog-path-pin/v1`: existing readers that ignore unknown object members retain their meaning, while witnesses aware of the field can enumerate what the pin excludes. | Cut only after the synchronous disk→CRDT sync pass returns and a second scan proves no changes remain other than the pin-declared exclusions. The pin is the real reflog checkpoint resolved through `Commonplace.Reflog.Restore`; the checkpoint and sync writes use the same explicit signing context and ordinary gated write path. | A git tree id, a git sha, a content-hash placeholder, an eventually-consistent/torn scan, or a pin reconstructed after the event silently. |
| `predecessor-ref` | Required object: `{branch: string, event-refs: [hex], unresolved: [string]}`. `event-refs` has zero entries for a first punctuation, one for an ordinary per-branch successor, and every distinct predecessor ref that can be resolved for a merge; there is no two-ref cap. `unresolved` names every merge operand whose event ref could not be resolved, rather than silently dropping it. | A worktree-local predecessor map, advanced only after the signed event lands. The current branch contributes its last event ref and every resolvable named merge source contributes another. | A timestamp ordering, a git parent sha, a branch name by itself, or proof that an unresolved merge parent never existed. |
| `git-sha` | Required nullable string. Non-null values are the 40- or 64-hex object name returned by `git rev-parse --verify HEAD` immediately before real git executes. | Read from the disposable local git scaffolding at tap time. `null` means there was no resolvable `HEAD` (for example, the first commit). | Event identity, a proto-pin, a predecessor reference, authority, or the resulting sha of an operation that has not executed yet. **Annotation only.** |

## Pin-cut and write ordering

For a landed event the required order is:

1. synchronously import the checkout's source state through the signed sync
   path, excluding `.git`, `.commonplace`, `_build`, and `deps`;
2. scan again and refuse emission if any disk/CRDT changes remain other than
   files named in the pin's `exclusions` list;
3. create and resolve the signed reflog checkpoint;
4. append this six-field object to the red event log using the principal's
   `SigningContext` through `CommitStoreClient` and the local trust gate;
5. after that write lands, advance the worktree-local branch predecessor to
   the enclosing event-log commit id;
6. execute real git. Event failure never blocks step 6;
7. when step 4 landed, append the signed post-exec annotation without syncing,
   pinning, or advancing the predecessor map.

The git operation occurs after the main event by design. Therefore `git-sha` is an
observation of pre-exec scaffolding, never the event's identity and never a
claim about the resulting commit. The correlated annotation is the witnessed
outcome.

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

After real git returns, a failed main emission's same envelope is updated and
fsynced with `post-exec.disposition: "skipped-main-emission-failed"`, the
resulting sha, git exit status, and final message. Thus the missing annotation
is explicit rather than silent. If the main event landed but its annotation
failed or returned without positive persistence confirmation, a separate
`append-at-replay` WAL envelope carries the complete annotation candidate.

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
unsigned WAL candidate directly into the store. Replay retains the
`predecessor-ref` recorded in the WAL candidate; it does not replace it with
whatever branch predecessor happens to be current at replay time. Content
addressing can make the replayed content pin equivalent when the source hashes
still match; the grade permanently records that the cut's timing was later.

## Explicit tap surface and full verb table

| Top-level git command | Proto-chit verb | Qualification |
|---|---|---|
| `commit` | `commit` | `commit --amend` is `rewrite`. |
| `cherry-pick`, `revert` | `commit` | — |
| `merge`, `pull` | `merge` | All named merge operands participate in predecessor resolution. |
| `branch`, `checkout`, `switch`, `tag`, `worktree` | `branch` | — |
| `rebase`, `reset`, `filter-branch`, `replace`, `update-ref`, `notes`, `bisect`, `reflog`, `stash` | `rewrite` | — |

Read-only commands pass directly to real git. The following write surfaces are
explicitly **untapped** because they do not declare a history/ref punctuation
boundary in v1: index/worktree preparation (`add`, `rm`, `mv`, `restore`,
`clean`), repository configuration (`config`, `remote`), object maintenance
(`gc`, `repack`, `prune`), transport-only operations (`fetch`, `push`), and
plumbing commands other than the explicitly tapped ref mutators above. Calling
an untapped command through an alias or shell script can hide a rewrite; pilot
usage therefore forbids aliases that expand to history/ref mutations.

## Open questions for pins-from-spec review

1. **Detached HEAD predecessor namespace.** v1 uses the literal branch
   `DETACHED`, so independent detached sequences share one local predecessor
   lane. Should true chit key detached lanes by the observed git sha instead?
2. **Unresolved merge operand vocabulary.** `unresolved` makes every miss
   explicit, but the canonical spelling for remote-tracking names, raw shas,
   refspecs, and option-owned operands still needs a parser contract.
3. **Event-log partitioning.** The pilot receives one configured event-log
   UUID. The stable rule for one-log-per-checkout versus one-log-per-principal
   remains deliberately unsettled.

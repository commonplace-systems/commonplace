# S37b build brief: the consumability proof — CX-5kb4

> **The work's ticket is CX-5kb4.** Context labels, none the citation:
> CX-fbah published yelixer (`64b2e51`, MIT at `691a4f4`) and is closed;
> CX-b6mz (flip) and CX-71m2 (delete `apps/yelixer`) are the ATOMIC round
> this gates and are NOT this round; CX-bx59 (standalone CI) follows.
>
> ⛔⛔ **THIS ROUND IS A GATE THAT CAN FAIL. IT IS NOT A BOX TO TICK.**
> Read the next section before anything else — it is the whole reason
> this exists, and a round that treats it as a formality has already
> failed.

## Why this round exists, and why "it probably works" is not enough

CX-b6mz stopped at its first question and the answer reshaped the arc.
There is one dependency edge and four possible states:

| state | `apps/yelixer` | dep declaration | result |
|---|---|---|---|
| A | exists | `in_umbrella: true` | today; works |
| B | exists | git | **Mix REFUSES** — measured |
| C | deleted | `in_umbrella: true` | a dep with no app; broken |
| D | deleted | git | the destination |

**Both intermediate states are unbuildable, so A→D is unreachable by any
single step.** The flip and the deletion are therefore ONE ATOMIC ROUND
— delete and flip in a single commit — which has a consequence this
round must carry:

⛔ **THE ATOMIC ROUND HAS NO INTERMEDIATE SAFE STATE.** "Stop and report
mid-round" — the thing that saved two rounds tonight — is unavailable
once it starts. Its revert is clean (one commit), but there is no place
to halt partway. ⇒ **S37b is the last place this arc can cheaply say
no.** Everything after it is either whole or reverted.

⭐ And one measured detail sharpens what you are proving: **Mix reported
that the umbrella source OVERRODE the external git source.** The
in-tree app does not lose — it silently wins. So a build that "works"
after a flip may be compiling the local copy while everyone believes it
is testing the published one. **The published artifact has therefore
never actually been consumed by anything, ever.** This round is the
first time it is.

## What to build

A **from-scratch external consumer** of the published library, and
nothing else.

1. **A fresh directory outside this repository** (a temp dir is fine —
   state where). A new `mix new` project, or a minimal `mix.exs`.
2. **Dependency on the published ref**:
   `{:yelixer, git: "https://github.com/commonplace-systems/yelixer.git", ref: "691a4f44a91039ecc02a8824a1a5fafa79d9c253"}`
   — or the `git@` form if that is what resolves in this environment;
   say which you used. ⛔ **Pin the SHA. Never `branch: "main"`.**
3. **Fetch and compile it** from the network, from that ref.
4. ⭐ **Run a REAL CRDT call — not `Yelixer.hello/0`.** The proof must
   exercise the library's actual purpose:
   - build a `Yelixer.Doc`, insert text into a named type,
   - encode an update (`Yelixer.Encoding.encode_update/1`),
   - apply that update to a SECOND, independently-created doc
     (`apply_update/2`),
   - assert the second doc's text **converges to the same value**.
   That is a real convergence assertion — the thing the library is
   for — rather than a smoke test that only proves the module loaded.
5. **Report what you ran and what it printed**, with the versions and
   the resolved ref.

## ⛔ The fences — every one of these would let the proof lie

- ⛔ **NO umbrella.** Do not run from, reference, or depend on this
  repository.
- ⛔ **NO local path dependency**, no `path:` override, no `override:
  true` pointing anywhere local.
- ⛔ **NO cached build and NO copied deps.** Do not reuse
  `/home/jes/commonplace/deps` or `_build`, do not set `MIX_DEPS_PATH`
  or `MIX_BUILD_PATH` at anything inside this repo. A fresh `deps/`
  fetched from the network is the point.
- ⭐ **Each of those would supply the answer by itself** — a local path
  or a warm build makes the check pass whether or not the published
  artifact is consumable. This arc has already hit that class twice
  tonight (a clone from a local repo that "verified" a publish; a blob
  found in an object store that the import itself put there). **State
  positively how you ensured none applied** — the absence of a flag is
  not evidence; show the resolved dep path.
- ⛔ **Change NOTHING in this repository.** No flip, no deletion, no
  mix.exs edit, no lockfile. The evidence note is the only file that
  lands here.
- ⛔ **Nothing is pushed to the yelixer repo.** No tag, no branch. This
  round only consumes it.

## Failure disposition — stated up front, because this gate is allowed to say no

If the consumer cannot fetch, cannot compile, or the convergence
assertion does not hold:

- ⛔ **The atomic delete+flip round DOES NOT RUN.** Nothing gets
  deleted.
- **Report the finding with its mechanism**; it gets its own ticket
  (report the identity — the gated verb is unreachable from the
  sandbox, which is a capability boundary, not a defect).
- **Do not work around it.** Do not add a path override to make it
  pass, do not vendor the code, do not repoint to a different ref to
  find one that works. A failure here is the arc's cheapest possible
  answer and its value is entirely in being reported honestly.

⚠️ **A "pass" that required any workaround is a FAIL.** Say what you
did, not just what happened.

## What lands in THIS repo

One evidence note under `docs/notes/`: the exact `mix.exs` used, the
resolved dependency path, the commands, the real output of the
convergence call, and a positive statement of how each fence was
honoured. That note is the artifact the gate is made of.

## Review criteria

Fresh dir outside the repo with the dep fetched from the network at the
pinned SHA (reviewer will check the resolved dep path, not the intent);
no local path, override, cached build, or copied deps — stated
positively, not merely unmentioned; a real convergence call exercised
and its output shown; the URL names `commonplace-systems` (with a
control that the grep would find `jes5199` if present); this repository
otherwise unchanged; the yelixer remote untouched — still 2 refs, no
tags, tip `691a4f4`.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). bd is a
frozen archive. ⚠️ **The verb is not reachable from inside the sandbox —
a capability boundary, not a defect and not a deviation, and not
something to route around.** Report identities; the reviewer files them.

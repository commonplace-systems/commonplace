# BUILD BRIEF — CX-vvbh: the node's own self-trust is dropped SILENTLY

**For:** Sol (codex) · **plan's #1 (suite reliability) — the PRODUCTION half of CI's #1 red**
**Worktree:** `/home/jes/sol-vvbh/wt` · **branch:** `sol/cx-vvbh`
**Run log:** `/home/jes/sol-vvbh/sol-run.log`

---

## 0. Environment contract (standing)

Named worktree off **current** `origin/main`; ⛔ leave changes **UNSTAGED**, no
`git add`, no commit, no push. ⛔ **No serve, no live store** — the live store is
`/home/jes/commonplace/workspace/.commonplace/commits/`, **process-derived, NOT
repo-root and NOT `data/`**. ⚠️ `mix deps.get` first.

⚠️ **rc from the command itself, never through a pipe.** ⛔ **NO BARE ZEROS.**
⚠️ Redirect long suites to a file; never pipe `mix test` to `tail`.
⚠️ **Umbrella test runs are MUTUALLY EXCLUSIVE on this box** — `commonplace_web`
binds :4002, so two at once collide and the loser dies `:eaddrinuse` with rc=1
and an EMPTY summary. Run them **one at a time**; an rc=1 with no counts is an
ENVIRONMENT error, not a test result.

⭐ **ESCAPE HATCH:** if the remedy below does not fit what you measure, **that is
a FINDING — report it and stop. Do not force it.**

## 1. The defect

`Commonplace.Trust.config/0` ends with `with_local_node_trust(base)`. That folds
the node's OWN identity into `trusted_identities`, which is what lets a **strict**
workspace keep accepting its own system-minted commits with zero pinning:

```elixir
defp with_local_node_trust(cfg) do
  with {:ok, identity} <- NodeIdentity.identity(),
       {:ok, [_ | _] = public_keys} <- NodeIdentity.public_keys() do
    ...fold identity => keys...
  else
    _ -> cfg          # ⛔ SILENT
  end
end
```

⛔ **The `else` returns the config unchanged and LOGS NOTHING.**

⚠️ **AND THE FUNCTION'S OWN COMMENT CLAIMS OTHERWISE** — this is the tell that a
signal was intended and never written:

> *"Best-effort: if the node key can't be sourced, the set is unchanged (the
> node's commits will then fail strict checks — **visible, not silent**)."*

⇒ **In production, a node that cannot source its own public key SILENTLY STOPS
TRUSTING ITS OWN COMMITS under strict posture.** Every self-signed write then
fails the gate, and the resulting `false` is **indistinguishable from a policy
decision** — the operator sees denials, not a missing key.

⭐ Reachable since `a4e708d` made `public_keys/0` **artifact-only**: both
`:absent` (no artifact) and `{:error, _}` (present but unreadable) now land in
that silent `else`. `CX-qvrz` exists precisely because the artifact CAN be
absent, so the window is real.

## 2. ⛔ SCOPE — make it LOUD, do NOT change the posture

⭐ **This ticket makes the degradation VISIBLE. It does NOT decide whether it
should fail closed.**

- ✅ **IN SCOPE:** emit a log at **error** when self-trust cannot be folded, and
  **distinguish the reasons.**
- ⛔ **OUT OF SCOPE:** making it refuse/raise/fail-closed. That is a posture
  change with an availability cost (a missing artifact would become a hard
  outage) and it is **plan's ruling, not this ticket's.** ⛔ **Do not implement
  it, and do not "prepare" for it.**

⭐ **Three outcomes must be distinguishable in the emitted event** — this is the
CX-1jh2 lesson applied to a third consumer:

| outcome | meaning |
|---|---|
| `:absent` | **no artifact** — plausibly a fresh node, still worth saying |
| `{:error, reason}` | artifact **present but unreadable** — something is wrong |
| `{:ok, []}` | artifact present, declaring **ZERO keys** — a statement, not an absence |

⚠️ Note `identity()` can also fail; if it does, say so distinctly rather than
folding it into the key cases.

## 3. ⛔ Acceptance — artifacts

1. ⭐ **RED FIRST:** a strict config + an absent/unreadable artifact **today** —
   show self-trust missing with **NOTHING emitted**. ⛔ **Prove the precondition**
   (print the artifact's actual state and the resulting `trusted_identities`) or
   the red proves nothing.
2. **After:** the degraded case is loud, and the event **NAMES which** of the
   outcomes in §2 occurred. Paste the actual log lines for **each** case you can
   construct.
3. ⭐⭐ **CONTROL — THE HEALTHY PATH STAYS QUIET.** A fix that logs on every
   successful boot is a new noise source and will be muted, which reproduces the
   defect with extra steps. Show a healthy config folding node trust and
   emitting **nothing**, with a positive control that your log capture **can**
   see output.
4. ⛔ **UPDATE THE COMMENT to say what the code does.** The stale
   "visible, not silent" claim is **part of the defect**, not documentation of
   it.

## 4. ⛔ Out of scope — the test half is NOT yours

⚠️ `TrustConfigFailClosedTest` currently FAILS (deterministically, 0.4s
isolated — it is `cp-ci-failures`' #1 with 12 occurrences). **It is filed
separately as CX-a2eb and you must NOT touch it.**

⛔ **Specifically: DO NOT hand-seed its fixture to make it pass.** Its fixture
lacks `node_signing_public_keys.json`, and that is one member of a POPULATION —
the same class as CX-8wh1's 44 fixtures lacking `node_signing_key`. plan has
ruled that a **complete-workspace fixture helper** is the shared fix for both.
⇒ **A local patch here would go green, close nothing, and leave the next reader
inferring the class was handled.**

⚠️ It follows that **your change may leave that test still red, and that is the
CORRECT outcome.** Report its status; do not chase it.

## 5. SUITES — by blast radius

`Trust.config/0` is read by anything that verifies a signature.

| suite | on-main count |
|---|---|
| ⭐ `apps/commonplace/test` | ⭐ **~3278 tests — THE WHOLE APP.** ⛔ A count in the HUNDREDS means you ran a subtree and **THE RUN IS VOID** |
| `apps/commonplace_web/test` | 12 features, 134 tests, 0 failures, 12 excluded |
| `apps/commonplace_mcp/test` | 156 tests, 0 failures |
| `apps/commonplace_cli/test` | 97 tests, 0 failures |

⛔⛔ **MAIN'S FAILURE SET IS NOT STABLE — DO NOT READ GREEN/RED DIRECTLY.**
Measured on `7b18534` at three seeds: **4, 1 and 4 failures, DIFFERENT SETS.**
⇒ **Baseline `apps/commonplace/test` at the SAME seed you test with, and compare
SETS, not counts.** A failure present in your run and absent from the baseline
is the only thing that indicts your change.

⚠️ Known-unstable, one line each if seen, do NOT pursue: `TrustConfigFailClosedTest`
(yours to leave red), `AuditChokePerfTest` (its ratio spans 2.815–4.941 against
a 3.0 limit — CX-d0sc/CX-dsqc), `BotPresenceCertTest` (60s timeout, fails
isolated on main too), `bounded persistence CX-i9ca`, the snapshot-walk-bound test.

## 6. What you cannot verify in-sandbox

- ⛔ Anything requiring the live serve — report **UNVERIFIED** and stop.
- ⭐ Every case in §3 is constructible from a fixture `data_dir`: an artifact is
  a file you write, delete, corrupt, or write empty.

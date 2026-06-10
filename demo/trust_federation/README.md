# Live two-node federation trust demo

Proves the trust gates (R1 import + R2 execute + 2.5 system-commit signing,
beads CX-tdkq.1 / .2 / .24) defend a **strict** node against an untrusted
federation peer — exercised over **real BEAM distribution** and the **real
sync/import code path**, not a mock.

## Run

```bash
bash demo/trust_federation/run_demo.sh
```

Brings up two real BEAM nodes from the umbrella:

- **Node B (`cpb`)** — a permissive peer. Authors three commits into its own
  `CommitStore`: a data commit *signed by a user A trusts*, an *unsigned* data
  commit, and an *unsigned code doc* whose `compute/2` would shell out
  (`System.cmd("echo", ["PWNED-BY-PEER"])`). Writes a manifest A reads.
- **Node A (`cpa`)** — strict (`accept_unsigned: false`), pinning the trusted
  user's public key. Connects to B and pulls B's commits via
  `Commonplace.Sync.NodeSync.catch_up/3` — the **same function
  `Cluster.EventHandler` calls on `:nodeup`** — which lands each commit through
  `CommitStore.import_commit` (Gate A). Then checks execution (Gate B).

## What it shows (6 checks)

**Part 1 — commit level (Gate A), over real catch-up sync:**
- signed-by-trusted data commit → **accepted**, persisted, content live on A
- unsigned data commit → **rejected** (`{:trust_rejected, :unsigned}`), not persisted

**Part 2 — RCE (Gate A + Gate B):**
- the peer's unsigned **code** doc → rejected at import, **never stored** on A;
  `SourceDoc.compile` → `{:error, :not_found}` (the shell-out never runs)
- defense in depth: an unsigned code doc that *is* present (authored locally —
  local creates aren't import-gated) → `SourceDoc.compile` →
  `{:error, {:execution_denied, {:untrusted_contributor, …, :unsigned}}}` — Gate B
  refuses to run it

## Honest scope

This proves **an untrusted commit/code arriving over the sync/import path is
rejected by the strict node** — the federation defense. It does **not** claim a
cookie-holding cluster member is contained: a BEAM cluster shares the
distribution cookie and is **one trust domain by design** (see
`trust-and-attenuation.md` §1 on commonplace-plan). The gate defends the import
seam; a distinct federation transport where cookie-sharing doesn't apply is
future work. The demo deliberately drives the import path (`catch_up` →
`import_commit`), which is exactly what that seam will use.

## Files

- `run_demo.sh` — launches both nodes, waits, captures A's transcript to
  `$SESSION_LOG` (default `/tmp/cp_fed_session.log`).
- `node_b.exs` — the peer: authors the three commits, writes the manifest.
- `node_a.exs` — the strict node: pulls, enforces, prints PASS/FAIL with the
  actual return values.

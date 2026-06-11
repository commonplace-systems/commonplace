# Live capability attenuation demo

Proves the phase-3 attenuable cert-DAG (CX-tdkq.22) end-to-end on **two real
BEAM nodes**: a strict node enforces a UCAN-shaped delegation chain on the
**real import path**, accepting a commit within its grant and rejecting four
distinct forgery/theft/over-grant attacks.

## Run

```bash
bash demo/trust_attenuation/run_demo.sh
```

- **Node B (`cpb`)** — a peer. Holds the capability certs (`store_capability`
  is ungated, so B can hold even the malformed ones a hostile peer would
  craft) and the one *valid* commit that A pulls. Writes a manifest.
- **Node A (`cpa`)** — strict (`accept_unsigned: false`), pinning **only** the
  root anchor key. Fetches the certs from B by CID over distribution (the
  federation envelope delivering the chain), then exercises its import gate.

## What it shows (5 checks)

1. **ACCEPTED** — bob's commit on `d1`, pulled cross-node via the real
   `NodeSync.catch_up`. Authorized by a `root→alice→bob` chain that verifies to
   the pinned root and grants `{write, d1}`. The doc content lands on A.
2. **REJECTED — forged-sig cert**: a chain whose leaf signature doesn't verify
   → `:invalid_signature`.
3. **REJECTED — over-broad cert**: alice grants bob `:execute` she never held
   (a narrowing violation, minted past the API guard the way a hostile
   delegator would) → `:not_attenuation`.
4. **REJECTED — stolen chain**: alice's *valid* chain attached to a commit
   signed by **mallory**, not bob → `:capability_author_mismatch` (the
   commit-author binding — the capability is bound to who actually signed).
5. **REJECTED — expired cert**: a valid narrowing whose `not_after` is in the
   past → `:expired` (valid at mint, dead at verify).

Each rejected commit is delivered to A's `import_commit` (Gate A) — the same
gate the sync path funnels through — and the verdict is read from the
`[:commonplace, :commit, :rejected, :trust]` telemetry plus the absence of the
commit in A's store.

## Honest scope

This proves **the strict node's import/sync gate enforces the capability
chain**. It is **not** a claim that a cookie-holding cluster member is
contained — a BEAM cluster shares the distribution cookie and is one trust
domain by design (see `trust-and-attenuation.md` §1). The gate defends the
import seam; the certs travel by CID over that same seam, and the chain
verifies **offline** against the locally-pinned root.

## Files

- `run_demo.sh` — launches both nodes, captures A's transcript to `$SESSION_LOG`
  (default `/tmp/cp_att_session.log`).
- `node_b.exs` — the peer: builds the cert chains, holds the valid commit.
- `node_a.exs` — the strict node: pulls, enforces, prints PASS/FAIL with the
  actual return values + gate reasons.
- `SAMPLE_SESSION.txt` — a captured run.

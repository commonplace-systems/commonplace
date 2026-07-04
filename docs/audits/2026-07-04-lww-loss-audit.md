# LWW-loss audit (CX-tdkq.30) — Find-1 fallout, 2026-07-04

Audit of all persisted CommitStores on this machine for the Find-1
(14520f7) pre-fix `origin=nil` map-overwrite loss. Detector:
`Commonplace.Audit.LwwLoss` (chain-order causal oracle vs reconstructed
views; see its moduledoc). Run offline against store copies with
`:reader_lazy_snapshot_enabled` disabled — no live store was touched.

## Verdict

- **No post-fix loss.** Zero findings with June/July-era content across
  all stores. The 2026-06-12 writer-side fix holds; the current
  wiki/outliner-era docs are clean.
- **Pre-fix damage is real but confined to disposable dev data.** jes
  ruled the affected stores intentionally disposable (2026-07-04):
  **no repair commits will be minted.** If any lost binding is ever
  wanted back, every finding's expected value is recoverable — the
  loser items are tombstoned, not erased (append-only store), so a
  forward repair (re-mint via `Schema.add_file` / `YMap.set`) can be
  scripted from a re-run of the auditor.

## Findings by store (9 stores audited)

| Store | Docs | Anomalous | Notes |
|---|---|---|---|
| `workspace/.commonplace` (49MB, live demo workspace) | 443 | 182 | ALL April 25 – May 9 (MUD/bot arc): presence keys (`status` ×76, `heartbeat` ×53, `last_seen` ×13), bot/schema entries (`claude-code.bot`, `bartleby`, `server`, `prompts.txt`/`output.txt`, `__reflog`/`__processes.json`/`__identities__`), reflog snapshots |
| `data/` (656KB, April MUD dev store) | 69 | 5 | 2 schema docs lost entries (`persona.md`, `bot.json` — hand-verified: 3 clients' writes ALL tombstoned `origin=nil`, key reads nil), 2 reflog_snapshot docs lost all metadata keys, 1 text doc lost root `_name`/`_type` |
| 7 others (escript-cwd fallbacks, worktree agents, `workspace/data`) | 0 | 0 | empty or trivial |

## Caveats

- The chain-order oracle treats commit-log position as causal order. For
  keys written concurrently by multiple writers (presence docs
  especially), legitimate CRDT LWW can pick a different winner than the
  chain-latest write, so the 182 count is an **upper bound** on
  Find-1-specific loss. The hand-verified cases (all writers' items
  tombstoned, key reads nil) are the definite-bug signature — legitimate
  LWW always leaves exactly one winner visible.
- The big store was audited in `full_replay: false` mode (production /
  reader-visible view only). The full-history replay **did not finish in
  2h41m** at 100% CPU (one core) — that measurement is recorded on
  CX-w1fw as production-scale evidence of yelixer's O(n²) bulk text
  replay; the production-only pass took 134s for the same store.

## Re-running

```elixir
# mix run --no-start, against a COPY of the store dir:
{:ok, _} = Application.ensure_all_started(:cubdb)
Application.put_env(:commonplace, :reader_lazy_snapshot_enabled, false)
{:ok, _} = Commonplace.Store.CommitStore.start_link(data_dir: copy_dir, name: :audit)
{:ok, findings} = Commonplace.Audit.LwwLoss.audit_store(:audit, full_replay: false)
```

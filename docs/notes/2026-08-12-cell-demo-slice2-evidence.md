# Cell demo slice 2 — federation receive leg: evidence (2026-08-12)

Companion to `2026-08-10-cell-demo-slice1-evidence.md`. Slice 2 = a second
workspace receiving cell-3's punctuation event over the pull-federation
transport. Every claim below is measured, with the artifact that carries it.

**ENCLOSURE (stated per the ratified witness condition): same box
(commonplace.astrolab.ist), same operator, HTTP loopback transport
(127.0.0.1:5201), bearer-token federation auth. Nothing here demonstrates
cross-machine or cross-operator federation.**

## What was proven

1. **Transport + Gate A import, end to end.** Receiver workspace ws2
   (`/home/jes/cell-1/ws2`, root `ac87fa9f`, `:minimal` profile) pulled
   cell-3's event-log doc `2c3a1ab2-7ac9-4e05-af88-f49d0cf171b7` from an
   ephemeral cell serve on :5201 via `Federation.PullClient` →
   `NodeSync.import_with_translation` → `import_commit` (Gate A verifies).
   Both commits arrived content-addressed and byte-identical (CIDs
   `429d02d6…` genesis, `c19dd555…` event — same ids on both stores).

2. **Receiver readback from its own store.** After adoption (see
   disposition), `RedLog.load` on ws2 returns the punctuation event:
   author-principal `0f38d1b7-6ab8-484b-a98f-c0ddcff7dc69` (cell-3's
   principal), git-sha `2228f525…`, predecessor-ref
   `cell/cx-lgfg-demo`, proto-pin checkpoint
   (`e459ad25…`/`054a9119…`) and **1,218 pin entries** — the fm7x
   declared-scope invariant readable across the federation boundary at
   full-world scale. Artifact: `evidence-full/46-slice2-adopt-readback.log`.

3. **Clean-cycle control.** With diff parity reached, one further
   `pull_once` returns `imported: 0, rejected: 0, errors: []` — the
   transport is quiescent, not silently retrying. Same artifact.

## Findings (both filed, live-store verified by re-read)

- **CX-5983 (p2, bug)** — composed receiver-side liveness failure, three
  seams measured in one run: (a) `MergeAdopter.maybe_adopt` adopts only
  `kind: :merge` commits, so a linear descendant imported from a peer never
  advances `:latest` and stays invisible to every latest-chain reader;
  (b) `PullClient.diff_missing` builds its denominator from the latest-chain
  walk instead of `all_commit_ids_for_doc`, so the stored-but-unadopted
  commit is re-offered every cycle; (c) `import_envelope` has no clause for
  `:already_exists`, so the re-offer crashes the whole pull cycle
  (`CaseClauseError`, `evidence-full/42-slice2-pull.log`). Last night's
  "imported=1 errors=[]" counted the body write, not readable adoption —
  the count reported on itself, not the effect. Store-vs-index divergence
  measured in `evidence-full/44-slice2-index-gap.log`.

- **CX-7cpf negative control (tripped, workaround on):** the receiver BEAM
  measured `{ProtoChit, Reflog.Snapshot} = {false, false}` before
  force-load — without the force-load, `Envelope.decode`'s
  `binary_to_term(:safe)` rejects the event envelope as `:bad_payload`
  (proven last night; this run kept the vocab loaded from the start). The
  at-risk population is **any fresh receiving BEAM**, not "remote nodes"
  specifically — slice 2 is same-box and still needs the workaround.

- **Refuted en route:** the "doc_uuid remap across epochs" hypothesis for
  last night's readback failure. The receiver held the sender's doc uuid
  and genesis CID verbatim; the missing event commit was the adoption gap
  above, nothing was remapped. Also noted: `RedLog.load` on a
  genesis-only chain fails as `:malformed_update` (decode of the 0-byte
  genesis update) — a misnamed error, store healthy (rider, not filed
  separately; belongs with CX-5983's fix review).

## Disposition of the manual step

The event commit was made readable by a **visible manual adoption**:
`CommitStoreClient.set_latest(ws2, event_log, c19dd555…)` after restating
its preconditions (commit present, Gate-A verified, strict descendant of
the then-current latest). This is the documented primitive, applied as an
operator act and recorded here precisely because the automatic path is the
defect CX-5983 describes. **"Slice 2 green" therefore means: transport,
verification, and readback are demonstrated; unattended receiver
convergence for linear history is NOT — it is CX-5983's acceptance.**

## Ops record

Cell serve ran as transient systemd user unit `cellserve2-slice2.service`
(MainPID 36947 captured at launch, MemoryMax=6G), peers armed post-boot via
erpc `put_env` (read at request time). Teardown by `systemctl --user stop`
of the unit only — no name-matched kills — with four checks green: unit
inactive, :5201 released, cell store fds released, live :5199 serve HTTP 200
and hermes untouched. Runbook: `/home/jes/cell-1/slice2-runbook.md`;
launch/arm/teardown logs: `evidence-full/40-…45-….log`.

# Trust & Attenuation — code-reality survey notes (checkpoint)

Date: 2026-06-10, branch `trust-attenuation` @ main 396b266.
Status: **R1 (CX-tdkq.1) and R2 (CX-tdkq.2) IMPLEMENTED on this branch.**
Design doc (complete, §1–8) lives in **commonplace-plan's repo**: `docs/trust-and-attenuation.md`.

## Implemented (this branch)

- `74e9dfd` nil-sig guard on `verify_commit/2`
- `dfa9eaa` `Commonplace.Trust.authorized?/3` seam — flat allowlist +
  `accept_unsigned` from workspace-local config (app env →
  `<data_dir>/trust.json` → permissive default)
- `7cbfc7e` Gate A: trust check in `import_commit`'s DEFAULT chain
- `7a12772` Document.Server respects the import verdict (bypass fix)
- `94e725f` identity-doc convergence via SiblingMerger (umbrella-shape
  metadata; full-chain reads)
- `e0d842e` Gate B: `Trust.authorized_to_execute?` contributor-chain walk
  inside `SourceDoc.compile` (laundering-proof; runs on cache hits)
- `24423a9` deterministic LRU stamps in SourceDoc (pre-existing flake)
- `f8f70c0` Gate B second ingress: `__processes.json` declaration gate
  (only protection for `:sandbox_exec`; revocation stops running
  processes via reconcile convergence)

Open follow-ups (relayed to commonplace-plan for beads): re-scope
CX-tdkq.21 (phase 1.5 largely subsumed); strict-mode hazard — unsigned
auto-snapshots brick code-doc executability; unsigned merge commits vs
strict federation import. Phase 3 (cert docs, CX-tdkq.22) awaiting
direction.

---

# Original survey (historical)

## Trust surface inventory (verified, file:line)

### Sign side — real and wired
- `apps/commonplace/lib/commonplace/crypto/signing.ex` — Ed25519 sign/verify over `commit.id`.
  - **`verify_commit` has ZERO production callers.**
  - API hazard: `verify_commit/2` with nil signature crashes `:crypto.verify` (unsigned guard only on `/1` head). R1 must-fix.
- `apps/commonplace/lib/commonplace/store/commit.ex` — signature/signer_id EXCLUDED from content address; sig over id transitively covers parent/update/metadata/merge_parents (metadata = deterministic term_to_binary). Solid foundation.
- `commit_store.ex:1248,1427-1453` — `maybe_sign_commit` on every create path; per-call `%SigningContext{}` (CX-hoj) or SecretStore fallback (`signing_key:default`/`signing_identity`); `:unsigned` opt-out.
- `signer_id = "identity_uuid@fingerprint"`, fingerprint = sha256(pub)[0:8].
- Gold attestation chain (`gold/chain.ex`, `gold/attestation.ex`): signed head-vouching, separate hash-linked per-doc chain. `attest verify` only checks against your OWN `signing_pub:default` — no peer key distribution exists.

### Verify side — vapor
- "__keys document" (mentioned in keygen.ex:7, signing.ex:7 moduledocs) **does not exist in code**.
- Only key registry: `presence/identity.ex:143-196` `add_public_key`/`get_public_keys` — a `public_keys` JSON list in `__identities__/<name>` docs. **Peer-writable synced CRDTs, zero auth → CANNOT anchor trust.** Trust roots must be workspace-local config; synced docs may carry only self-certifying material (signed delegation certs).

### Import chokepoint — one good seam, two bypasses
- `commit_store.ex:955-976` `handle_call({:import_commit,...})`: verify_id (content address, CX-gwz) → validator (`validator_for/2` at :1072, default = `Namespace.validate_commit_from_db`) → R11 pending-retry queue (:1117-1161, fixpoint retry after each landed import).
- Sig gate goes in the DEFAULT chain inside `handle_validated_import` (verify_id → sig gate → namespace), NOT as an opts validator (opts `:validator` overrides/bypasses; keep as test-only seam).
- **Bypass 1 (R1 must-fix):** `document/server.ex:292-307` `handle_info({:remote_commit,...})` IGNORES import_commit's return, applies update in-memory + `set_latest` regardless.
- **Bypass 2 (architectural, [DECIDED] with plan):** BEAM distribution = single trust domain (cookie → :rpc anything). Federation = NEW ingress seam, its own transport; import_commit+sig is the only door. R1 does not secure intra-cluster RPC and can't.
- Steady-state cross-node replication note: `Dataflow.PubSub.broadcast_commit` ({:remote_commit,...}) has no production broadcaster found; catch-up sync (`sync/node_sync.ex` via `cluster/event_handler.ex` on nodeup) is the live path.

### Execute side — zero gating; RCE + secret exfil
- `code/source_doc.ex:111` `SourceDoc.compile` → `Code.compile_string` on doc content. Narrow waist for BOTH callers:
  - `view/compute_runner.ex:71` ComputeRunner.compute (full-BEAM `compute/2` — arbitrary Elixir = RCE by construction).
  - `process/orchestrator.ex` — but NOTE: Orchestrator reads source itself via `read_source_with_uuid` (:470, has the full Commit in hand, discards signer) then calls SourceDoc.compile. **Gate must live INSIDE SourceDoc.compile.**
- Orchestrator walks the WHOLE tree collecting `__processes.json` from EVERY dir (:499) → federated write to any subtree = declare a process. `:sandbox_exec` (:405-433) resolves `$secret:KEY` from local SecretStore into spawned process env = **secret exfiltration**, plus OS command exec. Gate B covers both ingress points: SourceDoc.compile AND process-declaration.
- **ETS cache poisoning:** SourceDoc caches modules by content-hash only (:source_doc_index/:source_doc_cache). Revoking a signer doesn't stop already-compiled modules or already-running Orchestrator processes → cache must fold trust verdict into key or flush on trust-config change; Orchestrator needs a reconcile step stopping newly-untrusted processes. Phase-1.5 bead.

### R2 head-vs-chain (open with plan; my verified facts)
- `tree/doc_builder.ex:121` `reconstruct_snapshot` applies ONLY the latest commit to a fresh doc → compiled bytes come from exactly ONE commit (code-doc writers encode_update full state).
- BUT laundering vector is real at WRITE time, not reconstruct time: a trusted writer reconstructs (merging an untrusted commit's bytes), edits, re-commits full state under their signature → untrusted injection now inside a trusted-signed commit.
- Sound rule: every commit since the trusted baseline (genesis or trusted snapshot) must hold execute-for-scope. Chain walk is cheap (commit_log already walked elsewhere with limit 10_000); watermark cache is an optimization, not a requirement.

## Design convergence (with commonplace-plan, msgs #4909/#4911/#4913)
- Capabilities = signed CRDT docs, UCAN-shaped delegation DAG (proof = parent-capability ref), rooted at workspace-LOCAL config anchor (root pubkeys + accept_unsigned knob). Identity docs = convenience lookup, NOT load-bearing.
- Commit metadata carries proof-ref/hash (binds into content address → tamper-evident free; solves availability/ordering without doc-sync race). Cert docs = store of record; metadata = presented proof.
- Scope anchored on STABLE UUIDs (subtree-rooted-at-UUID), not paths (paths mutable via schema docs → gameable). Verbs = {write, execute, delegate} (+ maybe `secrets` caveat for $secret resolution). Attenuation = subset on verb set × scope + caveat tightening (not_before/not_after).
- Flat allowlist ships FIRST (R1/R2) as degenerate 1-link chain. Single boundary `Trust.authorized?(commit, verb, scope)` — phase-1 impl = allowlist, phase-3 = chain walk; gates never touch allowlist directly.
- R1 scope: sig verify in default import chain + accept_unsigned knob + identity-doc SiblingMerger convergence + fix server.ex:292 bypass + verify_commit/2 nil-sig guard.
- R2 scope: gate inside SourceDoc.compile (chain-since-baseline signer check) + Orchestrator __processes.json declaration gate + cache/revocation handling.

## Next steps (for resume after 20:00 quota window)
1. Read commonplace-plan's `docs/trust-and-attenuation.md` skeleton; contribute code-reality + gates sections.
2. Settle R2 chain-walk rule + watermark question with plan.
3. Bead out R1 + R2 (flat allowlist) with the above scopes; then implementation (subagents per global CLAUDE.md).

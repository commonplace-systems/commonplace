# Trust Phase 3 — implementation plan (attenuable capability cert-DAG)

Bead: **CX-tdkq.22** (epic CX-tdkq). Design: `trust-and-attenuation.md` §4 (commonplace-plan),
build-ready. This plan is the TDD build sequence + file:line targets so the build
window starts hot. Sub-beads 22a–e; subtree scopes are a separate epic (CX-tdkq.23).

## The spine stays fixed

`Trust.authorized?(commit, verb, scope)` is the **only** entrypoint both gates call.
Phase 3 swaps its *body*; Gate A (`commit_store.ex` `handle_validated_import/3`) and
Gate B (`source_doc.ex` `compile/2` → `Trust.authorized_to_execute?`) are **untouched**.

## Cert shape (converged §4)

```
%Commonplace.Trust.Capability{
  issuer:   {identity_uuid, pubkey},   # signs THIS cert; verify its sig against issuer.pubkey
  audience: {identity_uuid, pubkey},   # delegated-to key; the NEXT link's issuer, or the commit signer
  claim:    %{verbs: [..], scope: {:docs, [uuid..]}, caveats: %{not_before, not_after}},
  proof:    parent_cid | nil,          # nil only at a root cert
  issuer_pub: <pubkey>,                # = issuer.pubkey, inline for self-verification
  sig:      <Ed25519 over canonical(issuer,audience,claim,proof)>,
  id:       <CID = sha256(canonical(...)) — excludes sig>
}
```

CID determinism: canonical encoding serializes `scope` as a **sorted list of uuid
strings** and `verbs` as a **sorted list of atoms** (not a MapSet), `caveats` map under
`:erlang.term_to_binary(_, [:deterministic])`. Sig excluded (sig-over-CID, mirrors
`Store.Commit`).

---

## 22a — Capability value type (struct + CID + sign/verify + core mint)

**Mirrors `apps/commonplace/lib/commonplace/store/commit.ex` content-addressing.**

Files:
- NEW `apps/commonplace/lib/commonplace/trust/capability.ex` — struct, `content_address/4`,
  `new/4`, `verify_id/1`, `sign/2`, `verify_sig/2`. Copy the legacy-hatch/canonical
  discipline from `Store.Commit`, but serialize `scope` as a **sorted list of uuid strings**
  and `verbs` as a **sorted list of atoms** before hashing (MapSet is the runtime rep for
  subset checks, NOT the CID/wire contract); `caveats` map under `term_to_binary(:deterministic)`;
  sig EXCLUDED from the CID.
- `Capability.issue(issuer_ctx, audience_pubkey, claim, parent_cid \\ nil)` — mints + signs;
  **validates `child.claim ⊆ parent.claim` at issue time** when `parent_cid` given
  (defense-in-depth; `verify_chain` re-checks). Root: `parent_cid=nil`. Enough here to mint
  fixtures for 22b/22c; the ergonomic delegate API + CLI is 22f.

TDD: round-trip (new→verify_id), tamper→id_mismatch, sign→verify_sig, **two independent mints
of the same cert → same CID** (determinism), issue rejects a child exceeding parent.

## 22b — Capability CubDB storage

**Mirrors the attestation store in `commit_store.ex` (`store_attestation`/`latest_attestation`,
handle_call ~1010).** Add `store_capability/2` + `get_capability/2` + handle_calls:
`{:capability, cid} → cert`. Content-addressed CubDB entry, **NOT a CRDT doc** — certs never
merge; the CID-pinned entry enforces §4's value-not-state rule for free. Federation of cert
bytes is transport-inline + the pending queue, never doc-sync.

TDD: store→get by CID round-trips; get of an absent CID → `:none`; a tampered cert can't
masquerade (its CID wouldn't match — `verify_id` at read).

## 22c — `verify_chain`

**Mirrors `Trust.authorized_to_execute?`'s `reduce_while` walk (trust.ex).**

File: `apps/commonplace/lib/commonplace/trust.ex` (or a `Trust.CapabilityChain` submodule).

```
verify_chain(leaf_cid, anchor_keys, store) :: {:ok, %{verbs, scope, caveats}} | {:error, reason}
```
Walk leaf→root; per link:
1. fetch by CID (`get_capability`); missing → `{:error, :awaiting_capability}` (22d uses this).
2. `verify_id` (re-hash) + `verify_sig(cert, issuer_pub)`.
3. key-link: `child.issuer.pubkey == parent.audience.pubkey`.
4. **:delegate gate** — every NON-leaf cert's verbs must include `:delegate`.
5. monotonic narrowing: `child.verbs ⊆ parent.verbs`, `child.scope ⊆ parent.scope`
   (`MapSet.subset?` over the doc-uuid sets), `not_after ≤ parent`, `not_before ≥ parent`.
6. caveat window: `not_before ≤ now ≤ not_after` (now = `DateTime.utc_now()`).
7. root: `root.issuer.pubkey == the pinned full pubkey for that identity in anchor_keys`
   (full-byte compare — NOT "identity ∈ map"; the 32-bit fingerprint is forgeable).
Return EFFECTIVE = ∩verbs, ∩scope, tightest caveats.

TDD: 1-link root cert ok; 2-link delegation ok; child-exceeds-parent rejected; broken
key-link (full-pubkey mismatch) rejected; non-leaf missing :delegate rejected; expired
rejected; forged sig rejected; unknown/colliding-fingerprint root rejected; effective = intersection.

## 22d — `authorized?` phase-3 body + commit-author binding (the seam swap)

File: `trust.ex` `authorized?/4`. Gates unchanged.

```
(a) degenerate fast-path: signer ∈ locally-pinned trusted_identities (verify_commit
    against the pinned key) → :ok   # flat allowlist survives = implicit 1-link root
(b) else: leaf = commit.metadata[:capability_proof]; nil → reject (as today)
(c) ⭐ COMMIT-AUTHOR BINDING: Signing.verify_commit(commit, leaf.audience.pubkey) == :ok
    (full-pubkey; the cap holder is exactly who signed the commit; reuses the existing
    primitive). Without it, an attacker attaches ALICE's public leaf CID to THEIR commit
    and the chain still verifies → capability theft. THE load-bearing check.
(d) {:ok, eff} = verify_chain(leaf, anchor_keys, store);
    verb ∈ eff.verbs and requested-scope ⊆ eff.scope and window-ok → :ok | {:error, reason}
```
`anchor_keys` = the full pubkeys in `trusted_identities` (double-duty; no separate root_keys
field for MVP — §4 "allowlist entry = unattenuated root cert").

TDD: degenerate fast-path unchanged (R1/R2 tests stay green); delegated-cap commit
accepted for in-scope verb; rejected for out-of-scope/expired/wrong-verb; **author-binding:
commit signed by a DIFFERENT key than leaf.audience → rejected even with a valid (stolen) chain.**

## 22e — envelope: proof in metadata + pending queue

Files: `commit_store.ex` (create opts → `metadata.capability_proof`), the Gate-A trust
rejection path.
- Producer stamps `capability_proof: <leaf CID>` into commit metadata via create opts
  (binds into the content address → tamper-evident, §4).
- Gate A: when `authorized?` returns `{:error, :awaiting_capability}` (cert not yet present)
  → route to **`maybe_queue_pending`** (R11, `commit_store.ex:1117`) with reason
  `:awaiting_capability`, distinct from a hard untrusted-reject. `retry_pending_imports`
  fixpoint re-runs when certs land. Transport-inline of the chain is a noted future path.

TDD: commit with capability_proof whose cert is absent → deferred (not hard-rejected),
then certs imported → retry accepts; tamper of capability_proof CID → id_mismatch (free).

## 22f — issuance API + minimal CLI + peer-workspace cert

- Ergonomic `Capability.delegate(issuer_ctx, audience, claim, parent_cid)` (narrowing
  enforced at mint) + root self-issue; minimal CLI (`commonplace cap delegate/issue`).
- Peer-workspace trust as a cert: a root issues `{verbs:[:write], scope: peer-x doc-set,
  not_after}` to peer-X's root key (§4). MVP: doc-UUID-set scope.
- TDD: a peer-root-signed commit with the delegated chain is accepted within scope,
  rejected outside it; expiry honored; the full delegate→exercise round-trip end-to-end.

## Sub-bead map (locked with commonplace-plan, under CX-tdkq.22)

| bead | deliverable | mirrors | dep |
|---|---|---|---|
| 22a | Capability struct + CID + sign/verify + core `issue` | `store/commit.ex` | — |
| 22b | CubDB `{:capability, cid}` store + get | attestation handle_calls ~1010 | 22a |
| 22c | `verify_chain` (full-pubkey link, sig, expiry, :delegate gate, narrowing, effective) | `authorized_to_execute?` reduce_while | 22a,22b |
| 22d | `authorized?` phase-3 body + commit-author binding | `trust.ex` seam | 22c |
| 22e | `capability_proof` in metadata + pending `:awaiting_capability` | R11 `maybe_queue_pending` | 22d |
| 22f | issuance API + CLI + peer-workspace cert | — | 22a (feeds 22e tests) |

CX-tdkq.23 (subtree-scope, Wrinkle-H write-gated schema walk) is a **separate** epic;
MVP ships doc-UUID-set scopes.

## Open (track, not MVP-blocking)
- [OPEN F] revocation beyond supersession (short `not_after` + reissue is the MVP stance).
- [OPEN G] full key-rotation (MVP: rotation = new cert; in-flight certs don't re-point).
- [OPEN E] unify with white/macaroon substrate (kept separate through phase 3).
- CX-tdkq.23 subtree-scope (Wrinkle-H write-gated schema walk) — MVP ships doc-UUID-set.

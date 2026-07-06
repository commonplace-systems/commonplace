# Capability revocation — full design (CX-bepn)

**Status: plan-reviewed spine (keystone review, clod-squad #5696) with the
watermark catch + three semantic pins folded in. AWAITING plan's second
pass on this document before any build** — plan asked for the re-review
explicitly: this is the first mechanism where a MISSING record is
security-relevant. Author: commonplace (Fable). Strawman origin:
qat5.4 spec §3.

## 1. The mechanism

A **revocation record** is a content-addressed, signed statement that a
capability cert is void:

```
%Revocation{
  revoked_cid: cap.id,          # the cert being revoked
  revoker_pubkey: <32 bytes>,   # who says so
  sig: <Ed25519 over the canonical encoding>,
}
id = hash(revoked_cid <> revoker_pubkey)   # content-addressed, dedupes
```

- **Storage:** durable rows in the TrustSideStore keyed
  `{:revocation, revoked_cid}` (multiple revokers per cert allowed —
  row value is a list/set), beside the capability rows — the same
  carve-out home. All reads/writes via `CommitStoreClient` with the
  store argument threaded (the CX-ziye rule: a revocation lookup that
  silently consults the default store is a spurious-grant bug from day
  one).
- **No global in-memory set (plan addendum, #5700):** a global
  `persistent_term` revocation set would be the CX-ziye bug shape
  reborn — multiple stores sharing one set gives cross-store spurious
  denies AND spurious grants (a revocation in store A invisible because
  the set was built from store B). v1 does **per-link CubDB gets
  against the threaded store** — at dozens-scale revocations that is
  honestly fine; a cache was an optimization and correctness comes
  first. If telemetry (per-walk revocation-get count + timing) ever
  shows real cost, the later cache must be **keyed by store identity**,
  never global. Test pin: revocation written in store A denies in A and
  does NOT leak to store B (two named stores).
- **Verify:** `VerifyChain` consults the set per chain link. Any link
  revoked → terminal deny `{:error, :revoked}`. Transitivity is
  free-by-construction — any chain THROUGH a revoked link denies —
  and we state it rather than implement anything extra.

## 2. Revoker authority (pin P2)

A revocation record is valid iff `revoker_pubkey` is:
(a) an issuer on the revoked cert's **proof path** (root or any
ancestor delegator), OR
(b) the revoked cert's own **audience** (self-renunciation — the
compromised-key holder needs exactly this).

The verifier checks path-membership offline from the chain it already
holds — no new lookups. Authority is the record's signature itself
(.32-consistency: `cap revoke <cid>` needs no ambient authentication
path; an invalid-signer record is simply ignored, with telemetry).

## 3. Verify-time semantics (pin P1 — the philosophical one)

Revocation invalidates the cert for **all future verifies, including
Gate-B re-walks of historical contributions**. Consequences, owned
explicitly:

- A revoked contributor's past code contributions stop authorizing
  execution; the doc needs re-authorship by an execute-holder. This is
  the security WANT (same philosophy as trust-config eviction).
- Landed `:write` facts stay landed — history is append-only, commits
  remain as record — they just no longer *authorize* anything.
- NO timestamp-based "valid-when-signed" carve-outs: revocation-record
  times aren't trustworthy, and the complexity buys unsoundness.

## 4. The watermark catch (the load-bearing integration point)

`Trust`'s execute-clean cache is keyed
`{fp, commit_id}` with `fp = :erlang.phash2(cfg.trusted_identities)`
(trust.ex:274). A revocation changes effective authority WITHOUT
touching `trusted_identities` — stale cached verdicts would keep
honoring revoked certs at Gate B indefinitely.

**Fix:** `cfg_fingerprint` becomes
`:erlang.phash2({cfg.trusted_identities, revocation_set_hash(store)})`
— and per the per-store amendment, the set hash is **per-store**: a
small meta row (`{:revocation_meta, :set_hash}` in the TrustSideStore)
updated in the same write as each revocation record; the fingerprint
reads it through the threaded store (one get per walk, amortized over
the cached verdicts it protects). A new revocation therefore
self-invalidates every cached execute-clean verdict for that store —
revocation-at-Gate-B falls out of the existing config-change mechanism
for free. **Without this fold-in, revocation is decorative for code
docs** — it is a REQUIRED part of the build, with a test pin
(cached-clean doc → revoke contributor's cert → next execute check
re-walks and denies).

## 5. Supersession (pin P3)

Supersession = **reissue THEN revoke** (two records, new cert first) so
the holder never crosses a deny-gap. Operational ordering stated in the
API docs and the `cap` CLI (`cap supersede` mints in that order).
Partial narrowing ("remove one room from the section") is NOT
revocation — it is supersession (reissue-narrower + revoke-old),
preserving monotone-narrowing as the ONLY narrowing mechanism.

## 6. Federation

- **Transport:** revocation rows ride the SAME envelope/import path as
  capability rows — `Envelope`'s cert-chain collection extends to
  include known revocations for any cert in the chain; catch-up sync
  gossips revocation rows (tiny). Import of a chain containing a
  locally-known revoked cert = hard deny `:revoked` —
  terminal/present-and-invalid in the verify taxonomy, NOT
  `:awaiting_capability`/deferrable.
- **Eventual revocation, stated honestly:** absence-of-revocation is
  not provable over an async network. We accept eventual revocation
  and BOUND the window: short `not_after` caveats remain **permanent
  policy, not an interim hack** (revocation delivers intent fast;
  expiry guarantees the worst case for a peer that never hears it —
  the CRL-gossip + short-lived-certs stance). qat5.4's expiry beat is
  therefore kept forever, and this document is the reason nobody
  "cleans it up."

## 7. Interaction with Wrinkle-H (CX-tdkq.23)

Revocation attaches to the **cert CID, never the scope**. Subtree
scopes change what a cert covers, not the revocation unit —
revoke-by-cid is invariant under scope representation. No
scope-attached revocation records, ever; scope-shaped intent composes
as supersession (§5).

## 7.5 The two jes-visible semantics (flagged for veto, not blocking)

Per plan (#5700), the design needs no jes conversation IF these two —
the only decisions with user-visible semantics — are flagged so he CAN
veto; both follow existing house philosophy:

1. **Retroactive execute-invalidation (§3):** revoking a contributor's
   cert stops their historical code contributions from authorizing
   execution (re-authorship required). Same philosophy as trust-config
   eviction; landed writes stay landed.
2. **Watermark self-invalidation (§4):** a revocation invalidates
   cached execute-clean verdicts store-wide (one-time re-walk cost on
   next execute per doc). Same mechanism as a trust-config change.

## 8. Build shape (after plan's second pass)

1. `Trust.Revocation` struct + canonical encoding + sign/verify.
2. TrustSideStore rows + CommitStoreClient accessors (store-threaded) +
   persistent_term set + set-hash.
3. VerifyChain per-link check (terminal `:revoked`).
4. `cfg_fingerprint` fold-in + the cache-invalidation test pin.
5. `Capability.revoke/2` + `cap revoke` / `cap supersede` CLI.
6. Envelope/import extension + import hard-deny + catch-up gossip.
7. Demo: qat5.4's expiry beat gains a true-revocation sibling beat
   (X revokes Z mid-session; Z's next edit denies `:revoked`).

Test pins: authority matrix (path-issuer yes / audience yes / stranger
ignored), transitivity, cache invalidation (§4), import hard-deny,
supersession no-gap ordering, store-threading on a named store,
set-size telemetry.

# Federation For Real — agents as principals across trust domains

```
bash demo/federation_real/run_demo.sh
```

Two separate-rooted Commonplace workspaces as **two plain OS processes**.
No shared Erlang cookie. No epmd. No BEAM distribution. Node B is just
an HTTP URL to Node A — the claim the trust-arc demos explicitly could
NOT make (shared-cookie BEAM nodes are one trust domain by design).

## The cast

- **Node B** — the agent's home workspace. A human root **registers an
  agent** through the substrate (`Identity.register_agent`, CX-88mw):
  birth commits **creator-signed** (D9), keypair minted into SecretStore
  custody, pubkey bound into the identity doc. The root **delegates** the
  agent a write-scoped capability cert (the phase-3 cert-DAG — the same
  `cap delegate` that would grant a federated peer-root). The agent
  **authors commits signed with its own key**, stamping
  `capability_proof`. Bandit serves the federation endpoints
  (bearer-token gated, CX-orfw).

- **Node A** — a strict workspace in a **separate trust domain**. It pins
  exactly ONE thing: the root's public key. It pulls over plain HTTP
  (`PullClient`, CID-diff catch-up) and its **unchanged Gate A** decides
  what lands.

## What the gate proves

| Commit | Verdict | Why |
|---|---|---|
| Agent's in-scope commit | **ACCEPT** | signature verifies; cert chain (inlined in the envelope) verifies to the pinned root; commit-author binding holds; scope grants `{write, doc}` |
| Same agent, out-of-scope doc | **REJECT** | `capability_insufficient` — the cert never granted that doc |
| mallory-bot (signed, no cert) | **REJECT** | `untrusted_signer` — a valid signature is not authority |
| Wrong bearer token | **403** | the online layer ("may you talk") is not the import gate ("does this land") |

## Honest scope & notes

- **This is the real seam.** Transport is a dumb pipe; commits and certs
  are content-addressed, self-verifying values; authorization-to-land
  lives entirely at `import_commit` (Gate A). Cross-machine federation
  is this same demo with a non-localhost `base_url`.
- **Genesis commits don't federate under strict** — they're unsigned and
  the strict gate refuses them (you'll see them among the `rejected`
  count). That's benign: genesis is a *pure function of the doc uuid*
  (`Commit.genesis/1`); a strict peer mints its own locally instead of
  trusting one off the wire.
- **The `[:safe]` lesson (now baked into `Envelope`):**
  `binary_to_term([:safe])` refuses atoms not yet interned, and module
  loading is lazy — a fresh puller VM rejected valid envelopes until
  `Envelope` interned the wire format's closed atom universe at module
  load (`Envelope.wire_atoms/0`). This demo (fresh-VM puller) is the
  regression guard.
- `SAMPLE_SESSION.txt` is a captured passing run. `CP_KEEP_SHARED=1`
  keeps the scratch workspaces around for inspection; `SESSION_LOG=...`
  redirects Node A's transcript.

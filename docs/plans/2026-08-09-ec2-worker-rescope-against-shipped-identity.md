# EC2 worker: re-scoped against the identity surface that already shipped

2026-08-09. **A measurement, not an opinion about scope.** Every row is a
call site in `main` as of `f8ce129`.

The `2026-08-05-remote-worker-sandbox-design.md` §2/§6 was written with
explicit `VERIFY` markers against machinery that "was CX-88mw's shape." This
resolves them. ⭐ **Three of the capabilities it treats as work already exist;
one is a two-line extension of an existing helper; one is genuinely open — and
it is not the one the ledger flagged.**

⚠️ **Scope of this measurement:** `main` @`f8ce129`, source-read. ⛔ **It is
NOT a statement about the running serve, which is 35 tickets behind
(CX-y4bq).** Nothing here is live.

---

## The ledger, resolved

| Design assumed | Status | Call site |
|---|---|---|
| Worker mints **its own Ed25519 keypair** locally, never shipped from home | ✅ **SHIPPED** | `Crypto.AgentKeys.ensure/2` — mints idempotently into the node-local `SecretStore`, keyed `signing_key:<uuid>` / `signing_pub:<uuid>` |
| Key custody is **local**, lookup ≠ mint | ✅ **SHIPPED, and stronger than asked** | `AgentKeys.signing_context_for/2` is **lookup-only** — *"no minting here — that's `ensure/2`'s job"* |
| Home **grants certs to the worker's key**, audience-bound (anti-theft) | ✅ **SHIPPED** | `Trust.Capability.issue/5` + the binding at `trust.ex:178-179` and `:224-225` — `audience_pub == pub` |
| A **`:read` cert** the worker presents to replicate | ✅ **SHIPPED** | `Trust.Read.grant/4` → `{:ok, cap}`, cid presented as a `cert_cid`; enforced by `Trust.Read`'s gate |
| Worker **pins home's root key** in its `trust.json` | ✅ **SHIPPED** | `trusted_identities` map; `Trust.config/0` |
| Certs are **revocable** | ✅ **SHIPPED** | `Capability.revoke/2` (CX-bepn), enforced verify-time in `verify_chain` |
| **B4 `{:subtree, :write}`** — *"DESIGN … not built"* | ⭐ **THE GRAMMAR IS BUILT** | `Capability` `@type scope :: {:docs,…} \| {:presence,…} \| {:subtree, String.t()}`; enforced at `trust.ex:636` `grants?(%{scope: {:subtree, root}}, …)`. Shipped by CX-4u03 A1 (@f842fda, @b168f79) |
| **Non-pinned principal authorized by cert** | ✅ **SHIPPED** | `Trust.writer_authorized?/6` — pinned → true; **otherwise** any `cert_cid` granting write, chain-verified to anchors |

## ⛔ The two real gaps, and neither is what §6 listed

**① ⛔ A `{:subtree, R}` CERT CANNOT AUTHORIZE A READ AT ALL — and this is
bigger than a missing parameter.** *(Found by commonplace-plan; verified
here.)*

`Trust.Read.grant/4` hardcodes `claim = %{verbs: [:read], scope: {:docs,
[target_uuid]}}`, so it cannot MINT a subtree read. ⚠️ **But adding the
parameter would not be enough**, because the VERIFIER cannot consume one
either:

```elixir
# trust.ex — cert_grants_read?/5
{:ok, %{verbs: verbs, scope: {:docs, docs}}} <- VerifyChain.verify_chain(...)
  ...
else
  _ -> false        # ← a {:subtree, _} cert lands HERE
```

Compare the write side, which **has** the clause:

```elixir
defp write_scope_covers?({:docs, docs}, target_uuid, _store), do: target_uuid in docs
defp write_scope_covers?({:subtree, root}, target_uuid, store),
  do: doc_zone(target_uuid, store) == root
```

⇒ ⭐ **SUBTREE SCOPE IS ENFORCED FOR WRITE AND STRUCTURALLY INVISIBLE FOR
READ.** Day-one needs **both** halves: the scope parameter at the mint **and a
`{:subtree, _}` clause in `cert_grants_read?/5`.**

⚠️ ⭐ **AND THE FAILURE MODE IS THIS WEEK'S SIGNATURE: a `with` whose pattern
does not match falls through to a bare `false`.** The cert mints fine,
`verify_chain` passes, the audience binding holds — **and it simply never
authorizes anything, with no error naming the scope mismatch.** A silent
`false`, **indistinguishable from "not permitted."**

⛔ **CORRECTION TO THIS DOCUMENT'S FIRST VERSION**, which called gap ① *"a
parameter, not machinery."* ⚠️ **That was wrong, and the reason is instructive:
I reported "grep finds `{:subtree,_}` for `:define_verb` and write carves, not
for `:read`" as an absence of EXERCISE. It is an absence of the CODE PATH.**
⭐ **An absence needs its explanation before it can be sized — I recorded the
observation and did not chase the why.**

**② ✅ CLOSED — the worker is BEAM-resident by design, and the design says so.**
*(commonplace-plan; the answer was in the same document.)*

`2026-08-05-remote-worker-sandbox-design.md` **§0.1**: *"the worker is a PEER,
NOT A CLIENT: it runs its own local serve in the sandbox, federates with home
over HTTP, and works against its own replica."* ⇒ **`AgentKeys`' node-local
`SecretStore` custody applies as-is.**

⚠️ **I spent measurement on a question the document had already settled two
paragraphs before the `VERIFY` marker I was resolving.** The marker was hedging
about CX-88mw's per-agent machinery and READ as doubt about the worker's
residency. ⭐ **A hedge that contradicts its own document is worse than no
hedge.**

⇒ ⭐ **BUT THE DISTINCTION THE QUESTION SURFACED IS REAL AND IS NOW RULED — TWO
PRINCIPALS, TWO CUSTODY STORIES, AND CONFLATING THEM IS A SECURITY BUG:**
  · **EC2 worker = a PEER.** Runs its own node, **mints and holds its own key**
    via `AgentKeys`, federates to home. Everything in the table above applies.
  · **Sol/codex in a sandbox = NOT BEAM-resident, and MUST NEVER HOLD A KEY.**
    **The RUNNER holds custody and signs on its behalf** — which the
    sol-sandbox design already says.
⭐ **And that is the better posture anyway: the workload is the untrusted part,
so the key belongs to the supervisor, not the supervised.** ⚠️ **Conflating
them is how a sandbox acquires an identity nobody granted it — the
mint-on-missing trap arriving through the org chart instead of the code.**

## ⚠️ One design premise re-verified as STILL TRUE

> *"the zero-config default is `accept_unsigned: true`"*

`Trust.default_config/0` (trust.ex:1167) still returns
`%{accept_unsigned: true, trusted_identities: %{}}`. ⇒ ⭐ **"Enforce from
birth" remains a real provisioning requirement, not a historical note** — a
worker whose `trust.json` is not written explicitly comes up permissive, and
every gate on it is decorative.

## ⇒ What this changes about sizing

- **Day-one contribution** (read granted subtree, work locally, propose) needs
  **two changes, not one**: the scope parameter on `Read.grant/4` **and** a
  `{:subtree, _}` clause in `cert_grants_read?/5`. ⛔ **Shipping only the
  first mints a cert the verifier silently refuses.**
- **B4** is **smaller than "unbuilt"**: the cert primitive exists and is
  enforced. What is unproven is the **cross-repo audience** and the fact that
  subtree certs are **leaf-only**, which forbids the worker re-delegating.
- ⛔ **The delegation root is not a gate here either.** A worker signs with its
  own key under a home-delegated cert, and the commit reads *"this worker
  wrote it, under authority delegated by home"* — the honest record, available
  today with a single anchor.

⚠️ **What I did NOT verify:** that any of this works across a transport
(Slice-0 state), or anything about the running serve.
⭐ **And the one I recorded but did not chase — "grep found subtree usage only
for `:define_verb` and write carves, not for `:read`" — turned out to be gap ①
itself.** An absence I reported as a coverage observation was a missing code
path. **Chase the absence next time; it was the finding.**

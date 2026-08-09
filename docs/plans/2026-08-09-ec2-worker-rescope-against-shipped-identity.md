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

**① `Trust.Read.grant/4` cannot express a SUBTREE read.** It hardcodes

```elixir
claim = %{verbs: [:read], scope: {:docs, [target_uuid]}}
```

⇒ **Single doc only.** But `{:subtree, R}` is a first-class scope in the
grammar and `grants?/5` already evaluates it. ⭐ **So "a `:read` cert for the
project subtree" — the design's day-one requirement — needs a scope parameter
on an existing helper, not new machinery.** ⚠️ Two constraints to respect:
`check_subtree_leaf_only/2` makes `{:subtree,_}` **leaf-only in M2** (it cannot
be re-delegated), and `check_no_code_doc_in_scope/2` treats subtree scopes
differently from doc scopes.

**② The genuinely open one: does the worker run a commonplace node?**
`AgentKeys` custody is the node-local `SecretStore` (CubDB). ⇒ **If the worker
runs a commonplace node, the whole mint/custody story is reusable as-is.** If
it is a bare `opencode` sandbox with no BEAM, **none of it applies** and the
worker needs a different custody story entirely.
⭐ **§2's `VERIFY what's reusable for a non-BEAM-resident principal` is the
right question and it is still unanswered — it is an architecture question
about the sandbox, not a gap in the trust code.** ⛔ **Nothing else in this
table can be sized until it is settled**, because it decides whether the
answer is "reuse `AgentKeys`" or "build custody."

## ⚠️ One design premise re-verified as STILL TRUE

> *"the zero-config default is `accept_unsigned: true`"*

`Trust.default_config/0` (trust.ex:1167) still returns
`%{accept_unsigned: true, trusted_identities: %{}}`. ⇒ ⭐ **"Enforce from
birth" remains a real provisioning requirement, not a historical note** — a
worker whose `trust.json` is not written explicitly comes up permissive, and
every gate on it is decorative.

## ⇒ What this changes about sizing

- **Day-one contribution** (read granted subtree, work locally, propose)
  needs **the scope parameter on `Read.grant/4`** and nothing else from the
  trust layer.
- **B4** is **smaller than "unbuilt"**: the cert primitive exists and is
  enforced. What is unproven is the **cross-repo audience** and the fact that
  subtree certs are **leaf-only**, which forbids the worker re-delegating.
- ⛔ **The delegation root is not a gate here either.** A worker signs with its
  own key under a home-delegated cert, and the commit reads *"this worker
  wrote it, under authority delegated by home"* — the honest record, available
  today with a single anchor.

⚠️ **What I did NOT verify:** that any of this works across a transport (Slice-0
state), that `{:subtree, R}` read certs are exercised anywhere today — **grep
found subtree usage only for `:define_verb` and write carves, not for
`:read`** — or anything about the running serve.

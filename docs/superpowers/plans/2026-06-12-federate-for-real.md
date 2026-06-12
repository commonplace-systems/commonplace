# Federate For Real — Agents as Principals — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up real federation between two separate-rooted workspaces with an agent as a first-class signing principal — agent mints its own Ed25519 key, a human delegates it a scoped capability cert, the agent's signed commits cross a non-cookie transport, and the peer's strict import gate verifies signature + cert chain + author binding.

**Architecture:** Three phases. **A** closes the two strict-mode soundness gaps (CX-tdkq.26 unsigned translated commits, CX-tdkq.25 signing precedence) so strict mode survives real multi-epoch sync. **B** lands CX-88mw per-agent keys on the existing SigningContext/NodeIdentity patterns — minting, SecretStore custody, MCP session threading. **C** adds the minimal cross-trust-domain transport: a pull-based commit-exchange envelope over HTTP on the existing Phoenix endpoint, feeding the unchanged `import_commit` Gate A. The unifying design insight (commonplace-plan, msg 5081): a federated peer and an agent are the SAME mechanism at two granularities — both are external principals presenting signed commits + cert chains to a strict gate; the phase-3 cert-DAG already authorizes both.

**Tech Stack:** Elixir/OTP umbrella, Ed25519 via `:crypto`, CubDB SecretStore, Phoenix (commonplace_web) for the federation endpoint, phase-3 trust modules (`Commonplace.Trust`, `Trust.Capability`, `Trust.VerifyChain`) as-is.

**Design doc:** commonplace-plan `docs/federation.md` (in progress, commonplace-plan authoring). Trust background: commonplace-plan `docs/trust-and-attenuation.md`.

**Beads:** CX-tdkq.25, CX-tdkq.26 (Phase A); CX-88mw (Phase B); Phase C + D beads to be filed via the commonplace worker (sole bd-writer) once the transport question converges.

---

## Decisions ledger (converged with commonplace-plan unless marked OPEN)

| # | Decision | Resolution |
|---|---|---|
| D1 | Agents-as-principals vs federation: one mechanism or two? | **One.** Peer root = root-grained principal; agent = single-principal-grained peer. Same cert-DAG, same `cap delegate`, same Gate A. |
| D2 | Transport: shared-cookie BEAM distribution acceptable for dogfood? | **No.** Cookie = unrestricted RPC = one trust domain (demo READMEs already disclaim it). A non-distribution transport is required for any real cross-trust-domain claim. |
| D3 | Transport: port the Rust MQTT layer vs minimal HTTP envelope? | **HTTP envelope (lean, ~500-800 LOC).** There is NO MQTT in the Elixir tree (no deps, no broker, no macaroons — verified in mix.lock + grep). Commits/certs are content-addressed and self-verifying, so the transport stays thin and Gate A remains the only door. MQTT port re-evaluated only if a broker need (fan-out, offline queueing) emerges from dogfooding. *(Confirmed with commonplace-plan after premise correction — their MQTT lean was Rust-legacy.)* |
| D4 | Pull vs push sync over the new transport? | **Pull-first** (CID-diff catch-up over HTTP, mirrors existing `NodeSync.catch_up`). Push/streaming later if dogfood latency hurts. **(OPEN — awaiting commonplace-plan confirm.)** |
| D5 | Agent private-key custody | **SecretStore**, keys `"signing_key:<identity_uuid>"` / `"signing_pub:<identity_uuid>"` (base64, mirrors the `:default` slots). Node-local, never synced — the NodeIdentity pattern per-agent. `CommitStore.global_secret_context` is NOT touched; per-call SigningContext threading bypasses global slots by design. |
| D6 | Agent pubkey binding | Convenience copy in the identity doc via existing `add_public_key/3`; **authority comes from the cert, not the doc** (anchor rule from trust-and-attenuation.md). |
| D7 | CX-tdkq.26 fix shape | **Node-sign translated commits inside `Translator.translate_edit_with_snapshot/3`** (covers both auto-translate paths + positional fallback). Translation is a system action OF THE RECEIVING NODE → receiver's NodeIdentity is the principled signer, exactly the phase-2.5 pattern. Signature is outside the content address, so commit ids stay deterministic across nodes. |
| D8 | CX-tdkq.25 fix shape | Reorder `maybe_sign_commit/2` nil-branch: system kinds (`:snapshot`, `:merge`) node-sign BEFORE the global-SecretStore fallback. A snapshot is a system action, not a human one. |
| D9 | Who signs an agent's identity-doc registration in strict mode? | The registering caller's context (human/root, or node). `Presence.Identity` gains an optional `signing_context` opt threaded to its commits. |
| D10 | Key rotation scope for v1 | Minimal: `rotate/2` mints a new pair, appends the new pubkey to the identity doc (history preserved — `add_public_key` already appends), replaces SecretStore slots. As-of-commit-time verification semantics (chat-room.md) deferred. |
| D11 | Does node-signing translated commits launder `:write`-only contributions past Gate B on code docs? | **Real, but an instance of an EXISTING class — not a .26 blocker.** Gate B's walk (trust.ex `walk_contributors`) halts at the first `:snapshot` that passes `:execute`, and phase-1 trust is verb-agnostic, so node-signed snapshots (since 2.5) and node-signed merges already absorb write-only contributions into the execute baseline (the Gate B moduledoc's "merges are unsigned → conservative deny" claim is stale — fix in .26's commit). Disposition: (a) .26 proceeds; (b) v1 delegation-time policy: no write-without-execute certs scoped to code docs (documented in federation.md); (c) follow-up bead filed: "Gate B execute-baseline vs write-only contributors" — candidate fix is Gate-B-clean-stamped snapshots; (d) original-author metadata on translated commits is NOT a fix (metadata is attacker-writable — laundering vector). |

---

## File structure

**Phase A**
- Modify: `apps/commonplace/lib/commonplace/store/commit_store.ex` (maybe_sign_commit precedence)
- Modify: `apps/commonplace/lib/commonplace/store/translator.ex` (sign translated commits)
- Test: `apps/commonplace/test/commonplace/store/system_commit_signing_test.exs` (extend)
- Test: `apps/commonplace/test/commonplace/store/translated_commit_signing_test.exs` (new)

**Phase B**
- Create: `apps/commonplace/lib/commonplace/crypto/agent_keys.ex` (mint/custody/lookup/rotate)
- Modify: `apps/commonplace/lib/commonplace/presence/identity.ex` (signing_context opt)
- Modify: `apps/commonplace_mcp/lib/commonplace_mcp/anubis_server.ex` (session signing bootstrap)
- Modify: `apps/commonplace_mcp/lib/commonplace_mcp/tools/invoke_view_action.ex` (placeholder swap happens automatically once session context carries a real SigningContext — verify only)
- Test: `apps/commonplace/test/commonplace/crypto/agent_keys_test.exs` (new)
- Test: `apps/commonplace/test/commonplace/trust/agent_principal_e2e_test.exs` (new)

**Phase C** (provisional pending D4)
- Create: `apps/commonplace/lib/commonplace/federation/envelope.ex` (encode/decode commit + proof chain)
- Create: `apps/commonplace/lib/commonplace/federation/peer.ex` (peer config: URL + expectations)
- Create: `apps/commonplace_web/lib/commonplace_web_web/controllers/federation_controller.ex` (CID-diff + commit fetch endpoints)
- Create: `apps/commonplace/lib/commonplace/federation/pull_client.ex` (NodeSync-shaped, HTTP transport)
- Test: per-module + a two-workspace integration test

**Phase D**
- Create: `demo/federation_real/` (two separate-rooted local workspaces, agent principal, full round-trip)

---

## Phase A — strict-mode soundness (CX-tdkq.25 + CX-tdkq.26)

### Task 1: CX-tdkq.25 — system kinds node-sign before the global key

**Files:**
- Modify: `apps/commonplace/lib/commonplace/store/commit_store.ex:1544-1549` (the `maybe_sign_commit(commit, nil)` clause)
- Test: `apps/commonplace/test/commonplace/store/system_commit_signing_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `system_commit_signing_test.exs` (follow the existing setup pattern in that file — it already boots a store + NodeIdentity):

```elixir
test "snapshot in a keygen'd workspace is node-signed, not global-signed", %{store: store} do
  # Configure a global signing key (the keygen'd-workspace scenario)
  {global_pub, global_priv} = Commonplace.Crypto.Signing.generate_keypair()
  Commonplace.Store.SecretStore.set("signing_key:default", Base.encode64(global_priv))
  Commonplace.Store.SecretStore.set("signing_pub:default", Base.encode64(global_pub))
  Commonplace.Store.SecretStore.set("signing_identity", "human-uuid")

  # Mint a snapshot through the normal path (no explicit signing_context)
  snapshot = create_snapshot_for_test_doc(store)   # reuse this file's existing helper

  {:ok, node_identity} = Commonplace.Crypto.NodeIdentity.identity()
  assert snapshot.signer_id =~ node_identity,
         "system commit must carry NODE attribution, got #{snapshot.signer_id}"
  refute snapshot.signer_id =~ "human-uuid"
end
```

- [ ] **Step 2: Run it — must FAIL** (current order signs with the global key):
`mix test apps/commonplace/test/commonplace/store/system_commit_signing_test.exs`
Expected: new test fails with signer_id containing `human-uuid`.

- [ ] **Step 3: Implement** — reorder the nil-clause in `commit_store.ex`:

```elixir
  # CX-tdkq.25: system-minted commits (snapshot/merge) are SYSTEM actions —
  # always node-sign them, even when a global user key is configured, so
  # attribution is correct and zero-config single-node strict holds for
  # keygen'd workspaces too. Only non-system commits fall back to the
  # global SecretStore key.
  defp maybe_sign_commit(%Commit{metadata: %{kind: kind}} = commit, nil)
       when kind in [:snapshot, :merge] do
    node_sign_if_system(commit)
  end

  defp maybe_sign_commit(commit, nil) do
    case global_secret_context() do
      {:ok, ctx} -> sign_with_context(commit, ctx)
      :none -> commit
    end
  end
```

(`node_sign_if_system/1` already falls back to leaving the commit unchanged on `{:error, _}` — keep it; its non-system clause becomes dead and can be deleted.)

- [ ] **Step 4: Run the whole signing suite** — `mix test apps/commonplace/test/commonplace/store/system_commit_signing_test.exs` — all green, including the existing "regular user commits stay unsigned" and "Gate B accepts node-signed snapshot" tests.
- [ ] **Step 5: Full core suite** — `mix test apps/commonplace/test` (watch for tests that asserted global-signed snapshots; fix any to expect node signing).
- [ ] **Step 6: Commit** — `git commit -m "CX-tdkq.25: system-kind commits always node-sign, before global-key fallback"`

### Task 2: CX-tdkq.26 — node-sign translated commits

**Files:**
- Modify: `apps/commonplace/lib/commonplace/store/translator.ex` (~line 155, `translate_edit_with_snapshot/3`; also the positional-fallback mint — grep `Commit.new` in this file and route every minted commit through one signing helper)
- Test: `apps/commonplace/test/commonplace/store/translated_commit_signing_test.exs` (new)

- [ ] **Step 1: Write the failing tests** (new file; crib doc/edit/snapshot setup from the existing translator tests):

```elixir
defmodule Commonplace.Store.TranslatedCommitSigningTest do
  use ExUnit.Case, async: false
  # CX-tdkq.26: the cross-epoch translator runs with no user in the loop;
  # its output must be node-signed or strict Gate A rejects it.

  test "translated commit is node-signed" do
    {:ok, _kind, translated} = translate_a_late_edit()   # helper per existing translator tests
    refute is_nil(translated.signature)
    {:ok, node_identity} = Commonplace.Crypto.NodeIdentity.identity()
    assert translated.signer_id =~ node_identity
  end

  test "translated commit passes Gate A in strict mode" do
    {:ok, _kind, translated} = translate_a_late_edit()
    strict = %{accept_unsigned: false, trusted_identities: %{}}
    strict = Commonplace.Trust.with_local_node_trust(strict)
    assert :ok = Commonplace.Trust.authorized?(translated, :write, {:doc, translated.doc_uuid}, strict, CommitStore)
  end
end
```

- [ ] **Step 2: Run — must FAIL** (`signature: nil`).
- [ ] **Step 3: Implement** in `translator.ex` — sign at mint:

```elixir
        translated =
          Commit.new(
            edit.doc_uuid,
            translated_update,
            snapshot.id,
            %{kind: :regular, snapshot_parent: snapshot.id}
          )
          |> node_sign()
```

with one shared helper (also applied to the positional-fallback `Commit.new`):

```elixir
  # CX-tdkq.26: translation is a system action of the receiving node —
  # no user is in the loop and the original signature cannot survive the
  # byte rewrite. Node-sign so strict Gate A accepts the result. Signature
  # lives outside the content address, so ids stay deterministic.
  defp node_sign(%Commit{} = commit) do
    case Commonplace.Crypto.NodeIdentity.signing_context() do
      {:ok, ctx} ->
        signer_id = Commonplace.Crypto.Signing.signer_id(ctx.identity_uuid, ctx.public_key)
        Commonplace.Crypto.Signing.sign_commit(commit, ctx.private_key, signer_id)

      {:error, _} ->
        commit
    end
  end
```

- [ ] **Step 4: Run new file + existing translator/late-edit suites** — green. (`maybe_sign_commit`'s never-re-sign guard means the already-signed translated commit is untouched on import-side writes.)
- [ ] **Step 5: Fix the stale Gate B moduledoc** (D11) — in `apps/commonplace/lib/commonplace/trust.ex`, the `authorized_to_execute?` doc says "merge commits are minted unsigned today, so strict mode conservatively denies converged code docs". Post-2.5 merges ARE node-signed (see `system_commit_signing_test.exs` "merge commit … is node-signed"). Rewrite that paragraph to state the current truth: node-signed merges/snapshots pass Gate B and form the execute baseline; the write-only-contributor absorption caveat is tracked in the follow-up bead (see D11).
- [ ] **Step 6: Full `mix test apps/commonplace/test`** — green, no warnings.
- [ ] **Step 7: Commit** — `git commit -m "CX-tdkq.26: node-sign translated commits — strict-mode cross-epoch soundness"`

**Residual to note in the bead close:** a translated commit re-syncing to a THIRD strict node now carries node-B's signature — that third node must trust node B (peer node-key pinning or a root-issued cert), which is the documented multi-node cross-pinning gap (NodeIdentity moduledoc), not new exposure from this change.

---

## Phase B — CX-88mw: per-agent keys

### Task 3: `Commonplace.Crypto.AgentKeys` — mint, custody, lookup, rotate

**Files:**
- Create: `apps/commonplace/lib/commonplace/crypto/agent_keys.ex`
- Test: `apps/commonplace/test/commonplace/crypto/agent_keys_test.exs`

- [ ] **Step 1: Write failing tests** — covering: `ensure/1` mints once and is idempotent (same pubkey on second call); `signing_context_for/1` returns a `%SigningContext{}` whose pubkey matches; persistence across SecretStore restart (keys survive — they're CubDB-backed); `rotate/1` yields a new pubkey while `signing_context_for/1` returns the new one; unknown identity → `:not_found`.
- [ ] **Step 2: Run — fails (module doesn't exist).**
- [ ] **Step 3: Implement:**

```elixir
defmodule Commonplace.Crypto.AgentKeys do
  @moduledoc """
  Per-agent Ed25519 signing keys (CX-88mw).

  The per-agent analog of `Commonplace.Crypto.NodeIdentity`: private keys
  live in the node-local SecretStore (never synced), keyed by the agent's
  identity UUID. The public key is additionally appended to the agent's
  identity doc for convenience — but AUTHORITY comes from a capability
  cert delegated to the key (phase 3), not from the doc.
  """

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Store.SecretStore

  @doc "Mint (idempotently) a keypair for an identity. Returns {:ok, public_key}."
  def ensure(identity_uuid) when is_binary(identity_uuid) do
    case SecretStore.get(pub_slot(identity_uuid)) do
      {:ok, encoded} -> Base.decode64(encoded)
      :not_found -> mint(identity_uuid)
    end
  end

  @doc "SigningContext for an agent, or :not_found."
  def signing_context_for(identity_uuid) do
    with {:ok, enc_priv} <- SecretStore.get(priv_slot(identity_uuid)),
         {:ok, enc_pub} <- SecretStore.get(pub_slot(identity_uuid)),
         {:ok, priv} <- Base.decode64(enc_priv),
         {:ok, pub} <- Base.decode64(enc_pub) do
      {:ok, %SigningContext{identity_uuid: identity_uuid, private_key: priv, public_key: pub}}
    else
      :not_found -> :not_found
      :error -> {:error, :corrupt_key}
    end
  end

  @doc "Mint a replacement keypair. Old certs to the old key stay valid until expiry."
  def rotate(identity_uuid), do: mint(identity_uuid)

  defp mint(identity_uuid) do
    {pub, priv} = Signing.generate_keypair()
    :ok = SecretStore.set(priv_slot(identity_uuid), Base.encode64(priv))
    :ok = SecretStore.set(pub_slot(identity_uuid), Base.encode64(pub))
    {:ok, pub}
  end

  defp priv_slot(uuid), do: "signing_key:" <> uuid
  defp pub_slot(uuid), do: "signing_pub:" <> uuid
end
```

- [ ] **Step 4: Run tests — green.**
- [ ] **Step 5: Commit** — `git commit -m "CX-88mw(i): AgentKeys — per-agent keypair mint/custody/lookup/rotate"`

### Task 4: thread `signing_context` through `Presence.Identity`

**Files:**
- Modify: `apps/commonplace/lib/commonplace/presence/identity.ex` (`register/4` ~line 96, `add_public_key/3` ~line 208, `touch_last_seen/2`)
- Test: extend `apps/commonplace/test/commonplace/presence/identity_test.exs`

- [ ] **Step 1: Failing test** — in a strict-mode store with a pinned human key, `register(name, type, root, store, signing_context: human_ctx)` produces commits whose `signer_id` carries the human identity; same for `add_public_key/4` with context.
- [ ] **Step 2: Implement** — add a trailing `opts \\ []` to `register`, `add_public_key`, `touch_last_seen`; build `commit_opts = (ctx = opts[:signing_context]) && [signing_context: ctx] || []` and pass to every `CommitStoreClient.create_commit/create_chained_commit` call in those paths (including the `ensure_identities_dir` schema commits — thread `opts` down). Keep default behavior identical when no context supplied.
- [ ] **Step 3: Run identity + presence suites — green.**
- [ ] **Step 4: Add the binding convenience** — `register_agent(name, root_uuid, store, opts)`: `register(name, :bot, ...)` → `AgentKeys.ensure(uuid)` → `add_public_key(uuid, Base.encode64(pub), store, opts)` → returns `{:ok, uuid, pub}`. Test it.
- [ ] **Step 5: Commit** — `git commit -m "CX-88mw(ii): signing_context threading in Presence.Identity + register_agent"`

### Task 5: MCP session signing bootstrap (placeholder swap)

**Files:**
- Modify: `apps/commonplace_mcp/lib/commonplace_mcp/anubis_server.ex` (session init, where `presence_uuid` already lands in frame.assigns)
- Test: extend the MCP session/tool tests (`apps/commonplace_mcp/test/`)

- [ ] **Step 1: Failing test** — an MCP session with a registered agent identity invokes a chat post action; the resulting commit's `signer_id` is `"<agent_uuid>@<fingerprint>"`, NOT unsigned, and the audit payload no longer says `"mcp-agent@local"`.
- [ ] **Step 2: Implement** — at session init (next to existing presence bootstrap): `AgentKeys.ensure(presence_identity_uuid)` then `signing_context_for/1`, put `:signing_context` into frame.assigns / the session context map that `Tools.call` already passes through. `InvokeViewAction.derive_signer_id` (invoke_view_action.ex:199-204) already prefers a real SigningContext — no change needed there; verify the fallback is now unreachable for real sessions.
- [ ] **Step 3: Run MCP suite — green.**
- [ ] **Step 4: Commit** — `git commit -m "CX-88mw(iii): MCP sessions sign with real per-agent keys"`

### Task 6: agent-principal end-to-end test (the keystone proof)

**Files:**
- Create: `apps/commonplace/test/commonplace/trust/agent_principal_e2e_test.exs`

- [ ] **Step 1: Write the test** (this is the spec of the whole move, single-node first):

```elixir
# Strict workspace. Root (pinned human key) delegates a write-scoped cert
# to a freshly-minted agent key. The agent signs a commit carrying
# capability_proof = its leaf cert CID. Gate A: accepts. A second agent
# WITHOUT a cert: rejected {:untrusted_signer, _}. An agent whose cert
# scopes doc X must be rejected writing doc Y (scope narrowing).
```

Flow: `register_agent` → `Capability.issue(root_ctx, {agent_uuid, agent_pub}, %{verbs: [:write], scope: {:docs, [doc_x]}}, nil)` → store cert → agent creates commit with `signing_context: agent_ctx` + `capability_proof` metadata → `Trust.authorized?` under `accept_unsigned: false` with only root pinned.
- [ ] **Step 2: Run — make green** (this should pass with code from Tasks 3-5 + shipped phase 3; failures here are integration bugs — fix them).
- [ ] **Step 3: Full umbrella test run** — `mix test` (foreground, per test-suite-background-hang memory) — green, no warnings.
- [ ] **Step 4: Commit** — `git commit -m "CX-88mw(iv): agent-as-principal e2e — delegated cert + signed commit through strict Gate A"`

---

## Phase C — federation transport (provisional: pull-first HTTP envelope; finalize after D4 confirms)

> Gate A/Gate B/Trust are NOT modified in this phase. The transport's only job is moving self-verifying values (commits, certs) between stores; `import_commit` remains the sole ingress.

### Task 7: `Federation.Envelope` — wire format
Encode/decode: `%{commit: Commit-as-map, proof_cid: cid | nil, certs: [Capability-as-map]}` (certs inlined for availability — receiver stores them before importing the commit, so VerifyChain finds the chain locally). JSON; binary fields base64. Round-trip property test against `Commit.verify_id/1` and `Capability.verify_id/1` (tamper ⇒ id check fails).

### Task 8: federation endpoints on commonplace_web
`GET /federation/docs/:uuid/cids` (CID set for diffing) and `POST /federation/docs/:uuid/commits` (body: CID list → envelopes) — read-only serving; plus `POST /federation/import` (envelope in → store certs → `import_commit` → report accept/reject/deferred). Thin bearer-token auth (peer-shared secret in `trust.json`-adjacent config) — authorization-to-LAND remains Gate A's.

### Task 9: `Federation.PullClient`
NodeSync.catch_up reshaped: fetch remote CID set over HTTP (Req/Finch), diff (reuse `diff_commit_ids`), fetch missing envelopes, store certs, route each commit through `import_with_translation` (now safe cross-epoch thanks to Task 2). Poll on interval per configured peer (`Federation.Peer` config: name, base_url, token). Supervised, workspace-gated child.

### Task 10: two-workspace integration test
Two stores with separate data_dirs in one test node (no clustering, no shared cookie): workspace A strict, pins root; root delegates cert to agent on B; agent commit travels A←B via PullClient against a real Phoenix endpoint; assert landed on A with verified chain; assert an uncertified commit from B is rejected and telemetry `[:commonplace, :commit, :rejected, :trust]` fires.

## Phase D — live dogfood demo

`demo/federation_real/`: script in the style of `demo/trust_federation/run_demo.sh`, but **two separate-rooted workspaces, no shared cookie, different Erlang nodes entirely** — serve A (strict, port 4000) + serve B (port 4001), agent on B mints key, `commonplace cap delegate` from A's root to the agent, agent posts via MCP, PullClient federates it to A, A's gate verifies. README states honestly what is now proven that the trust-arc demos could not claim: **cross-trust-domain federation with an agent principal, no cookie**.

---

## Sequencing of Moves 2–4 (after Phase B lands; C/D can overlap)

1. **Move 2 — CX-tdkq.12 Orchestrator-on-boot** (after Phase A, independent of B/C): named singleton, workspace-gated supervision child, reconcile `cli/serve.ex:54` manual start. Blockers R1/R2 verified closed.
2. **Move 3 — Outliner MVP** (CX-saix → CX-sugc → CX-k8tn → CX-2qjd): independent track, can run in parallel with Phase C on a separate worktree/worker.
3. **Move 4 — Bursar dogfood, narrow** (CX-tdkq.7): retire `:global` MoveServer/TickBot split-brain before any multi-node deployment of the MUD; scoped to what singletons need.

## What this plan deliberately does NOT do
- No MQTT port, no broker (D3) — revisit only on demonstrated need.
- No revocation-beyond-TTL, no key-rotation as-of semantics, no subtree-scope resolution (CX-tdkq.23) — dogfooding generates those requirements.
- No changes to Gate A/Gate B logic, cert format, or chain verification — phase 3 ships as-is; this plan only gives it real tenants and a real wire.

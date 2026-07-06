defmodule Commonplace.WriterHand do
  @moduledoc """
  Shared derivation for the **hand** half of the actor/hand identity model
  (CX-41qg, design doc `2026-07-06-writer-identity-plan.md` on
  commonplace-plan). This module exists to converge NEW writers' hand
  derivation onto one call site; it does NOT replace the already-proven
  private `stable_client_id/1` helpers in `Sync.Agent` (CX-pyi),
  `CommandRouter` (CX-41qg.1), `Presence`, or `GitBridge.Inbound` — those
  stay as-is per "do not churn working code for aesthetics."

  ## The model, briefly

  Two identity facets exist and must not be conflated:

    * **actor** — an Ed25519 keypair. Security-bearing: it signs commits,
      it is what `Trust.authorized?` judges. Never derived here.
    * **hand** — a small integer namespace for concurrent Yjs edits within
      a document (the CRDT `client_id`). NOT security-bearing — anyone
      can claim any client_id at the CRDT layer; authenticity comes from
      commit signatures, never from client_ids. A hand has exactly two
      requirements: stability (reused across writes/restarts, or the
      state vector bloats forever) and uniqueness among CONCURRENT
      writers of the *same* doc (two live writers sharing a hand produce
      clashing clocks and corrupt the sequence — this is the hard
      constraint).

  ## Two derivation families, and why this module is only one of them

  The design doc (W2) resolves hands to a 53-bit space via
  `SHA-256(principal_pubkey || instance_nonce)` for *session*-shaped
  writers (browser tabs, agents) — each such writer mints and persists
  its own nonce once, so restart-reuse holds without a shared registry.

  This module implements the OTHER family: the **per-doc phash2 funnel**
  hand, `:erlang.phash2(uuid, 0xFFFF_FFFF)` — a **32-bit** range, not the
  53-bit session range above. That's deliberately narrower: it's safe
  here only because the population of CONCURRENT writers sharing a
  single funnel hand for a given doc is tiny (a server-side write funnel
  serializes its own writes per doc, so "concurrent" really means "this
  funnel plus at most a couple of other funnels that happen to touch the
  same doc" — Sync.Agent and CommandRouter converging on the same
  phash2(uuid) is the intended convergence, not a collision). At that
  scale the 32-bit birthday bound is negligible; it would NOT be safe to
  reuse this narrower range for the session-hand family, which has to
  cover many more concurrently-live identities and needs the full 53-bit
  headroom W2 specifies. Do not widen this module to double as the
  session-hand deriver — keep the two families separate.

  ## Adopted convention (reconciliation with W2, acked by the plan @ c43505c)

  W2's text names CommandRouter as getting "one node hand" (a single,
  whole-server identity). W1 implemented something narrower instead:
  **one hand PER DOC** (`phash2(uuid)`), not one hand for the whole
  funnel. This is the convention actually adopted, for two reasons: (1)
  it converges CommandRouter and Sync.Agent onto the SAME client slot
  for any doc both touch — fewer total hands workspace-wide than two
  independent single node-hands would produce — and (2) it's already a
  proven, tested pattern (CX-pyi / CX-41qg.1). The per-doc scheme is
  therefore the adopted server-funnel convention for every writer fixed
  in this sweep (CX-41qg.3), not a deviation from the plan.

  ## Asymmetric deconfliction (funnel hands vs. session hands)

  The two families deconflict DIFFERENTLY when a hand collision is
  discovered at binding-registration time (a hand's first use, checked
  against `client_namespaces`):

    * **Funnel hands (this module) never move.** `phash2(uuid)` is a
      deterministic, nonce-free function of the doc's own uuid — there is
      no nonce to re-roll, and moving it would break the exact
      convergence property point (1) above depends on. If a collision is
      ever observed here it is a bug to fix (e.g. a hash-space clash),
      not a signal to re-derive.
    * **Session/agent hands (the W2 SHA-256(pubkey‖nonce) family) are the
      side that re-derives.** They carry an instance nonce precisely so
      they CAN mint a fresh one and re-register on conflict — funnel
      hands have no such escape valve, so the burden of resolving any
      cross-family or intra-family collision falls on the nonce-bearing
      side, never on the deterministic funnel side.

  ## When NOT to use this module

  Only for docs where sharing this per-doc hand across every writer that
  uses it is safe. That holds for:

    * Server-funneled writers serializing writes per doc (CommandRouter,
      Sync.Agent, the write funnels fixed under CX-41qg.3).
    * Semantically single-writer documents (an actor's own presence doc).

  It does NOT hold for documents with genuinely concurrent distinct
  writers sharing state (e.g. `Presence.Identity`'s shared identity doc,
  which derives its own scheme combining workspace + writer-instance
  identity — see that module's moduledoc). Never point two DIFFERENT
  concurrent writers of the same doc at this same derivation without
  checking that invariant first.
  """

  @doc """
  Derive a stable, deterministic per-doc hand (Yjs client_id) from a
  doc's own uuid. Pure function — stable across restarts by
  construction, no persistence needed. 32-bit range (`0xFFFF_FFFF`) —
  see moduledoc for why that's narrower than the 53-bit session-hand
  space and why that's fine here.
  """
  def for_doc(uuid) when is_binary(uuid) do
    :erlang.phash2(uuid, 0xFFFF_FFFF)
  end

  @doc """
  Derive a stable, deterministic per-(doc, actor) hand. Same family and
  range as `for_doc/1` (deterministic, nonce-free, never re-derives),
  but keyed by the writing actor as well as the doc.

  Use this instead of `for_doc/1` for docs with genuinely CONCURRENT
  distinct writers — e.g. a chat room's `_messages` doc, where several
  actors (users, bots, bridges) post through separate processes with no
  serializing funnel between them. Sharing one per-doc hand there
  violates the model's hard constraint (uniqueness among concurrent
  writers): two actors that reconstruct the same base state and mint
  ops concurrently would collide on (client_id, clock), and the loser's
  ops are silently skipped as duplicates on replay — permanent lost
  writes (reproduced during CX-41qg.3 review; see CX bead trail).

  Keying by actor removes the cross-actor collision while keeping the
  bloat bound: one client-id slot per actor per doc, not one per write.
  Two concurrent sessions of the SAME actor can still collide — that
  residual window is what per-session hands (W4 / CX-qat5.2, the
  53-bit nonce-bearing family) exist to close.
  """
  def for_doc_actor(uuid, actor) when is_binary(uuid) and is_binary(actor) do
    :erlang.phash2({uuid, actor}, 0xFFFF_FFFF)
  end
end

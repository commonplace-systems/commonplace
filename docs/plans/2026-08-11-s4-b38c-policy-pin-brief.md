# S4 build brief: pin the code-authoring cert policy — tests + docstring truthing, no mechanism build

> Basis: plan's CX-b38c mechanism ruling, READ IT FIRST — it is in the
> COMMONPLACE-PLAN repo: /home/jes/commonplace-plan/docs/notes/
> 2026-08-11-code-authoring-mechanism-ruling.md (@fc48157). The headline:
> the mechanism ALREADY EXISTS — the belt's own condition admits a
> {:subtree,R}[:write,:execute] cert; capability_path/grants? are
> verb-agnostic; Gate-B's walk takes cert proofs today. This round is
> POLICY-PINNING TESTS plus truthing two docstrings, not a build.
> Buffer position: after S3. Lands with-or-before the runner (plan).

## ⛔ Escape hatch, up front

Stop and REPORT instead of building if:
- Any of the pin tests FAILS in the direction that requires a PRODUCTION
  code change (e.g., something in the chain does refuse an
  execute-carrying cert, contradicting the ruling's code reading). The
  ruling says no production change is required; a red that demands one is
  a finding that goes back to plan.
- The revocation test (below) reveals the watermark-cache gap plan flagged
  as likely. DO NOT fix caching in this round — record the failing test
  as the deliverable for that arm (an honest red with a named mechanism),
  report, and leave the fix to its own round.
- ⚠️ Sandbox: trust anchors resolve EMPTY here (node key masked) — build
  every chain from FIXTURE roots/contexts the way subtree_carve_test.exs
  does; a wave of :untrusted_root against fixture-less chains is the
  fence, not a defect.

## The pins (each a test; crib: subtree_carve_test.exs + local_write_gate_test.exs)

All with a fixture root, a zone subtree, and certs minted from fixture
contexts; writes carry `%{kind: :regular, capability_proof: cert.id}`:

1. w+x cert, CODE-classified write IN-subtree → LANDS (the belt's own
   conjunction admitting it — the sanctioned door).
2. w-only cert, code write in-subtree → REFUSED (the demo's third control,
   pinned as a permanent test if not already one — check first; the demo
   proved it live but a suite pin may not exist).
3. w+x cert, any write OUTSIDE the subtree → REFUSED (scope still binds).
4. Attenuated child cert (w-only derived from the w+x parent via the
   existing chain), code write in-subtree → REFUSED — monotone-meet
   delivering spawn-safe sub-agents with zero new machinery.
5. Gate-B contributor walk: a commit authored under the w+x cert is an
   execute-clean contributor (walk green with the proof carried).
6. ⭐ REVOCATION: after revoking the w+x cert (the shipped content-addressed
   revocation, CX-bepn), the SAME contributor is REFUSED by the walk.
   Plan flags this as the arm most likely to catch a real gap (the walk's
   watermark cache keys on the config fingerprint) — see the escape hatch
   if it does.

## The docstring truthing (two sites, accuracy not enforcement)

trust.ex:197 ("a citizen never holds") and :242 ("Gate-B, node-only")
describe the cert population minted so far, not a mechanical restriction.
Per the ruling: make them ACCURATE — ":execute is delegable by explicit
cert; no cert carrying it had been minted before CX-b38c" (wording sense,
not verbatim requirement). No behavior change.

## Out of scope, stated so it cannot creep

- No mint ceremony (S5-tier, jes-ratified, per-cell; IEx ceremony is fine
  when it happens). No CLI mint path (runner lane). No manifest code.
- No safe-verb/AST-allowlist changes (route (ii) rejected).
- No caching fixes (escape hatch above).

## Gates

- The new test file(s) + trust test files + full core suite; counts
  reported. `mix compile --warnings-as-errors` clean. Tmp stores only.

## Deliverable

Work left UNCOMMITTED for the operator to land. Report: per-pin results
(1-6) with commands, the revocation arm's outcome stated plainly
(green / red-with-mechanism), the docstring diffs, test counts, deviations.

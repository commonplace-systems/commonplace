# S11 build brief: `cert-mint` CLI — the runner-lane mint path, closed by default

> Plan's ruling (msg 11205), transcribed — the grammar and postures are
> dictated; no surface invention. The IEx ceremony is the acceptance
> ORACLE: same inputs must yield the same cert, byte-for-byte.

## ⛔ Escape hatch, up front

Stop and REPORT if:
- The serve-side mint endpoint doesn't exist and creating it requires more
  than routing an HTTP call to the existing Capability.issue path under the
  node's signing authority (a new authz surface is a design question, not a
  route addition).
- Byte-for-byte parity with the IEx ceremony fails for any reason other
  than timestamps — a cert that differs structurally means the CLI path
  diverged from Capability.issue, which is the exact defect this oracle
  exists to catch.
- ⚠️ Sandbox: the serve is NOT reachable from your sandbox and the node
  key is masked — serve-integration arms are UNVERIFIED-in-sandbox by
  construction. Build against the same seam the CLI's other serve-backed
  commands use, test with fixture stores/contexts locally, and NAME the
  unverified arms in your report (the operator runs them live).

## The command (dictated)

`commonplace cert-mint --scope REF --verbs LIST --audience PRINCIPAL [--expiry E]`

1. `--scope` takes the EXISTING ref grammar (bare = path, `:` = UUID,
   `@` = CID) — no new addressing invented; resolve exactly as the CLI's
   other ref-taking commands do.
2. `--verbs` is an explicit comma list with NO DEFAULT — closed by
   default: a mint that doesn't name its verbs REFUSES. ⛔ Verb omission
   must never quietly mint write-only, and especially never quietly mint
   w+x (this is the S4-pinned policy's mint-side guard).
3. `--audience` is the principal (identity uuid); `--expiry` optional.
4. Output: the cert CID. Nothing else on stdout (scripts consume it).
5. Transport per the standing architecture rule: one-shot CLI → HTTP to
   the local serve; the mint executes under the NODE's signing authority
   server-side; the CLI never touches key material.
6. The leaf-only limitation is a NAMED refusal when someone attempts to
   chain from a CLI-minted cert — a stated limit, never a surprise (the
   refusal text says leaf-only and why).

## Tests (red-first where a behavior exists to contrast)

- Verb omission → refusal naming the flag (closed-by-default arm).
- Scope grammar: all three ref forms resolve (fixture store).
- The parity oracle: mint via the CLI path's core function AND via the
  Capability.issue ceremony with identical inputs → byte-identical certs
  (modulo any timestamp field — if one exists, pin it in the test).
- Chain-from-CLI-cert attempt → the named leaf-only refusal.
- Serve-transport arm: exercised at the seam locally; the LIVE arm named
  UNVERIFIED for the operator.

## Gates

CLI app suite + trust/capability test files + full core suite; counts
reported. `mix compile --warnings-as-errors` clean. Tmp stores only.

## Deliverable

Work left UNCOMMITTED for the operator to land. Report: the parity-oracle
evidence, refusal texts verbatim, unverified arms named, test counts,
deviations.

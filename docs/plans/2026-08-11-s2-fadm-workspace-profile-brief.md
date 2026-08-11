# S2 build brief: Workspace.initialize/2 takes a workspace PROFILE — minimal cells birth without bd/ or chat/

> Plan's ruling ② (msg 11155): the workspace CLASS declares what gets
> minted; explicitly NOT "stop minting bd/chat" — other classes want them.
> Plan frames this as #12's first concrete manifest field arriving as code.
> Buffer position: after S1.

## ⛔ Escape hatch, up front

Stop and REPORT if:
- The bd/chat mint turns out NOT to run under `Workspace.initialize/2`'s
  control (e.g., it fires from an app-boot ensure that initialize cannot
  reach) — the live evidence says a fresh init minted both within seconds
  (cell-2's chain: one unsigned commit adding chat+bd at birth), but FIND
  THE MINT SITE FIRST and report it; if it is boot-side, the fix shape
  changes and this brief's mechanism is wrong.
- Threading the profile seems to require changing `commonplace init`'s CLI
  interface incompatibly. A new optional flag is fine; changing existing
  behavior is not.

## The defect (CX-fadm, measured 2026-08-10)

Every fresh workspace root gets `bd/` and `chat/` schema entries minted by
the substrate. An import-only cell can never converge them, so (pre-
symmetric-excludes) the CORRECT torn-state refusal refused forever; even
now they are unwanted structure in a cell's pinned world.

## The property

1. `Workspace.initialize/2` accepts a profile option (e.g.
   `profile: :default | :minimal` — name it well; it is #12's first
   manifest field). `:default` = today's behavior EXACTLY, for every
   existing caller (no caller updates needed beyond the cell path).
2. `:minimal` births a workspace with NO bd/ and NO chat/ — and whatever
   else the mint site adds beyond the root marker, enumerate it and decide
   per-item with the enumeration in your report (nothing dropped silently).
3. The CLI exposes it (`commonplace init --profile minimal` or similar),
   default unchanged.
4. The profile is RECORDED in the workspace (a readable artifact — e.g. in
   the root meta or a marker the store carries) so a pin's world can state
   its class rather than it being inferred. Keep it simple; this is the
   seed of the manifest, not the manifest.

## Tests (red-first)

- RED-FIRST: fresh init on unmodified code → root schema contains bd + chat
  (record it). After: `:minimal` init → contains NEITHER; `:default` init →
  byte-for-byte today's entry set. Both asserted by reading the store back
  (reconstruct + entries), never by init's exit code.
- The recorded-profile artifact is present and readable in both profiles.
- Existing init tests keep passing untouched.

## Gates

- Workspace/init test files + CLI app suite + full core suite (init is a
  shared seam) — counts reported. Tmp stores only.
- `mix compile --warnings-as-errors` clean.

## Deliverable

Work left UNCOMMITTED for the operator to land. Report: the mint-site
finding, the enumeration of what `:minimal` excludes, red-first verbatim,
test counts, deviations.

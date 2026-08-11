# S2v2 build brief: workspace profile — recorded at init, CONSULTED AT THE MINT SITES

> Supersedes 2026-08-11-s2-fadm-workspace-profile-brief.md after its escape
> hatch fired (mint sites are NOT under initialize). Amended mechanism
> RATIFIED by plan (msg 11177): initialize RECORDS the profile artifact;
> the mint sites CONSULT it. Basis, now the ruling's own: a profile
> consulted at the mint sites protects the workspace for its LIFETIME, not
> its birth — cell-2 showed re-mint pressure is continuous, so an init-time
> skip would be re-minted over at the next CLI boot.

## The mint sites (enumerated by the S2 run — verify they're still the set)

- `chat/`: application-boot hook — application.ex:208 →
  `Chat.TemplateBootstrap` (builds /chat/__template with five children).
- `bd/`: lazy — `Bd.Workspace.ensure_bd_dir/3` on access (CLI bd commands
  invoke it; cli/bd.ex:27).
- `Workspace.initialize/2` itself mints nothing beyond the empty root
  schema — it is where the profile gets RECORDED, not enforced.

## ⛔ Escape hatch, up front

Stop and REPORT if:
- A third mint site exists that the enumeration missed (grep for writers to
  the workspace root schema outside sync/user paths before building).
- Reading the profile at the boot hook requires app-env plumbing that
  can't distinguish WHICH workspace is booting (the hook must consult the
  profile OF THE WORKSPACE IT IS ABOUT TO MINT INTO, not a global).

## The property

1. `Workspace.initialize/2` accepts `profile: :default | :minimal`
   (default `:default` — every existing caller byte-for-byte unchanged)
   and RECORDS it as a readable workspace artifact (this is #12's
   manifest-field-zero; keep the artifact simple and store-carried so a
   pin's world can state its class).
2. The chat boot hook consults the target workspace's recorded profile:
   `:minimal` → skip template-minting entirely (a debug line, not silence);
   `:default` or ABSENT (pre-profile workspaces) → today's behavior.
   Absence means default here by explicit decision — record that in the
   artifact's doc comment (it is the one place absence-is-consent is
   correct: pre-existing workspaces predate the field).
3. `ensure_bd_dir` for a `:minimal` workspace: **SKIP with a debug line**
   (plan's decision, made in this brief): return a value the caller
   handles as not-present rather than minting. ⛔ NAMED CHECK, not an
   assumption: enumerate every `ensure_bd_dir` caller and verify each
   handles the not-present return; a caller that DEPENDS on the dir
   existing after the call is a FINDING to report, not absorb (plan's
   condition ②).
4. CLI: `commonplace init --profile minimal` (or equivalent), default
   unchanged.

## Tests (red-first)

- RED-FIRST: on unmodified code, boot-mint a fresh workspace (drive the
  boot hook the way the app does) → chat/ appears; invoke a bd path →
  bd/ appears (record both). After: `:minimal` workspace — chat/ NEVER
  minted across a boot-hook invocation, bd/ NEVER minted across an
  ensure_bd_dir call, both asserted by reading the root schema back; and
  the RE-MINT arm: invoke the mint paths a SECOND time on the :minimal
  workspace — still nothing minted (the lifetime property, the arm the
  original mechanism would have failed).
- `:default` workspace: byte-for-byte today's entries after the same
  sequence.
- Absent-profile (legacy) workspace: today's behavior (the explicit
  absence-means-default arm).
- The recorded-profile artifact is present and readable in both profiles.

## Gates

- Workspace/init/bd/chat test files + CLI app suite + full core suite;
  counts reported. `mix compile --warnings-as-errors` clean. Tmp stores.
- ⚠️ Sandbox: fixture contexts; trust anchors empty in here.

## Deliverable

Work left UNCOMMITTED for the operator to land. Report: the caller
enumeration for ensure_bd_dir with each one's not-present handling named,
the third-mint-site grep result, red-first verbatim including the re-mint
arm, test counts, deviations.

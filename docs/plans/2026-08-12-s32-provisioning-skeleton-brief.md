# S32 round-1 build brief: the runner provisioning skeleton, LOCAL-FIRST — CX-gkxa (runner arc round 3)

> **The work's ticket is CX-gkxa.** Any doc line citing a ticket cites
> CX-gkxa — no other id. Context labels, none the citation: CX-brxx was
> S30 (Cell.Manifest, landed @688cfbb3 — refuse-at-birth field-named,
> read/1 with its which-case marker); CX-3shs was S31
> (Runner.PodProfile, landed @58d8344d); the manifest schema's §4 is
> the birth-certificate contract this round implements four-fifths of.
> Plan sized S32 as "likely 2 rounds" — THIS IS ROUND 1: provision and
> VERIFY a local pod; NO worker process launches inside it (round 2 /
> S33 territory). One unknown per rung: locality first; remoteness is a
> later rung and nothing here may assume or prepare for it beyond not
> blocking it.

## What round 1 builds

`Commonplace.Runner.Provisioner` (naming yours): given a validated cell
manifest + a validated pod profile, provision a POD ON THIS BOX:

1. **Pod home**: a pod directory (location convention yours — somewhere
   runner-owned, stated in the moduledoc) holding the checkout and the
   workspace data dir.
2. **Sandbox SPEC from the profile**: derive the bwrap invocation
   (binds, masks, workdir) from `profile.sandbox` — as a DATA structure
   the round can test (the spec, not a running sandbox; executing it
   with a worker inside is round 2). The six standing masks from the
   dispatch ceremony (node_signing_key, secrets, .erlang.cookie, .ssh,
   .config/gh, .claude/channels) are the floor — state them in the
   spec's construction, not as convention.
3. **Checkout**: a git worktree or clone of the repo at a stated sha
   into the pod home (mechanism yours; worktrees are the fleet's
   pattern and cheap).
4. **Workspace birth per the manifest** (schema §4, steps 1/3/4/5 —
   step 2, the cert mint, is S33's and is NOT built here):
   `Workspace.initialize` with the manifest's `workspace_class`; sync
   scope configured from `manifest.sync_scope` — an absent scope
   REFUSES (S1b); `root_entries` amendments through the loud path if
   any; the SLA tier stamped into the workspace's storage declaration.
   Then the manifest itself written into the born workspace via
   `Cell.Manifest.create` (post-field workspaces always carry one —
   the temporal exception self-retires here, on the first
   runner-born world).
5. ⛔ **THE ENFORCE-FROM-BIRTH ASSERTION — the ruled re-arm, the
   round's reason for existing**: after initialize, the runner path
   ASSERTS the born workspace's trust posture — enforce, accept_unsigned
   false, per the S4 pins — and FAILS THE BIRTH on any mismatch with
   the posture field named. A pod whose world came up permissive is not
   a pod; it is a refusal. This assertion must be a test-covered code
   path, not a comment.

**REFUSE-AT-BIRTH, field-named, throughout**: any manifest field the
provisioner cannot satisfy refuses with the field named
(enforce-from-birth generalized to the whole manifest, schema §4's
closing contract). The refusal surface follows S30's idiom
(`{:invalid_manifest, field, reason}`-shaped) so the two read as
siblings.

## Matching at provision time (a STATED decision — hatch if it proves wrong)

Instance-time `requires` matching (a recipe's versioned
`{postgres: ">=14"}` vs the profile) is INSTANCE territory (S38) and is
not built here. At POD provision the runner performs a NAMES-ONLY
hosting check: `manifest.environments.requires_allowed` (bare service
names) must be a subset of `profile.services` keys — refusing with the
service named if the vessel cannot host what the cell may declare. If
building this reveals the check belongs elsewhere or needs versions,
STOP and report rather than widening it.

## ⛔ Escape hatches, up front

- Any manifest field the runner cannot satisfy → refuse-at-birth with
  the field named; if satisfying it would need machinery this round
  doesn't have (certs → S33; instances → S38), the refusal names the
  missing machinery — report the list, don't build ahead.
- NO worker process launches inside the pod. NO remote anything. NO
  cert minting. If the skeleton seems to need any of them, stop.
- The live serve and its workspace are NOT this round's world: all
  provisioning targets fresh pod-local stores. Nothing here touches
  `workspace/.commonplace` or the serve. (Tests build their own
  fixture manifests/profiles — S30/S31's test helpers are reusable.)
- Telemetry events in scope: NONE.

## Tests (red-first; suites named with counts)

Baseline: take the then-current full core count and SAY IT (my last
measured: 3,431/0 + 1 skipped @b95bb53e).

- **Birth happy path**: fixture manifest (minimal class) + fixture
  profile → pod provisioned; assert BY EFFECT: workspace exists with
  the manifest's class recorded, the manifest readable via
  `Cell.Manifest.read` as `{:stored, ...}` from the born world, sync
  scope present, SLA stamped.
- **Enforce-from-birth arm (the point)**: a birth that would come up
  permissive (fixture arranges it) → FAILS with the posture field
  named; and the positive control — the enforcing birth passes the
  same assertion.
- **Refuse-at-birth arms**: absent sync scope → S1b refusal named;
  unknown workspace_class → named; requires_allowed ⊄ profile services
  → refusal naming the service.
- **Sandbox-spec arm**: the derived bwrap spec contains the six
  standing masks and the profile's shape — asserted as data.
- **No-worker pin**: the provisioner's result contains no running
  process; nothing spawned (assert by construction/result shape).
- Prove any "pre-existing/unrelated" failure with an isolated rerun —
  licenses "outside this diff's footprint", not "flaky under load".

## Review criteria

Enforce-from-birth assertion is a tested code path failing on
permissive; every refusal carries its field/service name; the sandbox
spec carries the six masks as constructed data; §4 step 2 visibly NOT
built (a comment naming S33 where it would go); the names-only hosting
check stated with its hatch; no serve/live-store contact (reviewer
greps for the live data dir and serve node name); full core count
reconciled.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). bd is a
frozen archive and answers "no issue found" for everything since
2026-08-05. A round that cannot file via the verb reports identities
for the operator, stated as a deviation.

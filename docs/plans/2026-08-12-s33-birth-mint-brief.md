# S33 round-1 build brief: the birth mint + the cold-start pair — CX-d59r (runner arc round 4)

> **The work's ticket is CX-d59r.** Any doc line citing a ticket cites
> CX-d59r — no other id. Context labels, none the citation: CX-gkxa was
> S32 (Runner.Provisioner, landed @a0b59f1e — birth per schema §4 steps
> 1/3/4/5, step 2 marked NOT BUILT with a comment naming S33; that
> comment is this round's insertion point). CX-37d9 (private-key mint
> create-once, FIXED @390433f8, open pending this re-arm) and CX-kmtq
> (node_id cold-start rename, UNFIXED) ride here **as ruled long ago —
> "the runner build was always their re-arm" (QUEUE.md S33 row)**; they
> close at landing, by the reviewer, not by this round's code. CX-b38c's
> ruled route is pinned by S4 @a9e78e95; the mint surface is S11's
> @550be28d. NO worker launches this round — that fence has not moved.

## Half 1: §4 step 2 at the marked point

At the comment in `Provisioner.initialize_and_verify/3` that names S33,
the runner REQUESTS THE CERTS THE AUTHORITY BLOCK NAMES (manifest
schema §4 step 2, `commonplace-plan docs/plans/2026-08-12-cell-manifest-schema.md`):

1. **The mint is the S11 ceremony core, aimed at the pod world**:
   `Commonplace.CertMint.mint/5` already accepts everything this needs
   explicitly — `:issuer_context` (the pod node's signing context,
   already in hand at that point), `:store` (the pod store),
   `:root_uuid` (the born root), `:audience_resolver`. Use them. ⛔ NOT
   the HTTP endpoint (that is the live-serve lane), and NO new
   `Application.get_env` reads may enter the provisioner or cert paths
   — the S32-landed moduledoc names the env seam as a hazard; this
   round must not deepen it.
2. **`authors_code` translates per the b38c ruling / S4 pins**: the
   cell's principal receives ONE leaf `{subtree, born-root}` cert —
   verbs `[:write, :execute]` when `authors_code: true`, `[:write]`
   when `false`. No other verbs, no defaults anywhere (S11's
   omission-refuses discipline carries over). Expiry: none for birth
   certs this round — state that in the moduledoc as a decision, not
   an accident.
3. **The born manifest records ACTUAL authority**: the minted cert CID
   is written into `authority.certs` before `Manifest.create`, so the
   birth certificate names the authority that really exists. Assert by
   effect: re-read the born manifest, resolve the CID in the pod
   store, and prove the cert BINDS — the S4 pin helpers are the
   oracle (w+x code-in-subtree lands; w-only code refused
   `:capability_insufficient`).
4. **A fresh world cannot carry pre-minted certs** (stated decision):
   an input manifest with non-empty `authority.certs` REFUSES at birth
   naming `authority.certs`. If building this reveals a legitimate
   pre-listed-cert case (adoption, migration), STOP and report — do
   not widen.
5. **The ratification transcription**: §4's words are "the ratification
   moment; jes for now, the adoption record when it exists." The
   runner does NOT re-ask: the validated manifest in hand IS the
   ratified input, and its provenance is the provisioning caller's
   responsibility. Put that sentence (adapted, not decorated) in the
   moduledoc where the mint happens.

**The principal's key (stated decision — hatch if it proves wrong)**:
`CertMint.mint` requires the audience's public key, and a fresh pod
world contains no registered identities, so `provision/3` gains an
explicit `:principal_pubkey` opt — the caller who ratified the
manifest hands over the principal's public key with it. Absent opt
while the authority block requires a mint → refuse-at-birth naming
`principal` ("public key not provided to provisioning"). A
non-UUID `principal` will also surface here as a field-named refusal
(existing fixtures use names like "principal-a"; S33 fixtures must use
real UUIDs + a real generated keypair). If building this shows the key
belongs in the manifest schema or a registry handshake instead, STOP
and report — that is plan's schema territory, not this round's.

## Half 2: CX-kmtq — the cold-start window's silent half

`Workspace.write_fresh_node_id/2` (workspace.ex:203) still writes
through the FIXED temp name `.node_id.tmp` and a clobbering
`File.rename` — the exact defect CX-37d9 closed on the private-key
path, and this half is SILENT: two racing first-boots can walk away
holding different node ids. Its comment ("both callers see the same
final value") claims a safety the rename does not provide — the
comment goes with the fix.

- **The remedy property** (mechanism proven by 37d9's landed fix at
  node_identity.ex, use its pattern): create-once publication —
  `File.ln/2` with `:eexist` meaning someone else won, READ THEIRS
  BACK; temp name unique per machine (OS pid + random bytes —
  `System.unique_integer` is per-VM, and shared-data_dir cold start is
  the multi-node case this was filed for); temp unlinked on publish.
- **Red-first**, in the shape of `node_identity_race_test.exs`, and
  ⭐ with DIVERGENT VALUES as its own failure arm separate from errors
  — 37d9's decisive lesson: the prescribed unique-temp-alone fix
  stayed red only because the test classified divergence separately;
  "no error" would have gone green on a worse defect.
- **Truth the cross-reference**: node_identity.ex:245's comment names
  this defect as still-live at a drifted line number; after the fix it
  must say fixed, and point correctly.
- The runner birth path (every pod first-boot mints identity through
  this code) is the pair's ruled re-arm; the reviewer closes CX-37d9
  and CX-kmtq at landing on this round's evidence. This is a
  local-filesystem race, fully provable in suite — the
  population-correct close needs no live arm.

## ⛔ Escape hatches, up front

- Anything the mint cannot satisfy → refuse-at-birth, field named,
  refusal naming missing machinery where machinery is the gap
  (registry/adoption records are future rounds).
- NO worker launches. NO remote. NO live-store or serve contact — all
  births target fresh pod-local stores; the CertMint HTTP
  endpoint/controller files are not touched.
- The `with_workspace_env` global-env seam is NOT replaced this round
  (its S32 moduledoc sentence promises S33 — TRUTH IT: the
  worker-launch round is the real gate, name that instead). The fence
  is narrower and checkable: the DIFF adds no new global-env reads.
- Telemetry events in scope: NONE.

## Tests (red-first; suites named with counts)

Baseline: full core 3,438 / 1 known-unrelated GitBridge teardown flake
(CX-2h03, proven load-attributed by isolated rerun 17/0) / 1 skipped
@a0b59f1e. Say the count you measure; prove any red outside this
diff's footprint with an isolated rerun before claiming it
pre-existing.

- **Birth-mint happy path ×2**: `authors_code: false` → born manifest
  carries exactly one cert CID, resolvable in the pod store, verbs
  `[:write]`; `authors_code: true` → `[:write, :execute]`, and the S4
  pin oracle proves code-in-subtree lands under it while the w-only
  cert's code write refuses `:capability_insufficient`.
- **Refuse arms**: non-empty input `authority.certs` → named; absent
  `:principal_pubkey` → named; non-UUID principal → named.
- **kmtq race**: red-first against the clobbering rename; divergent
  node_ids its own arm; green under the create-once fix.
- **S4 pins**: the six S4 policy tests stay green (no policy drift).
- **No-worker pin persists** (S32's test still passing counts).

## Review criteria

The S33 comment is REPLACED by the mint call (grep: the string "S33"
gone from provisioner.ex); no default verbs (grep for a verbs default);
diff adds zero `Application.get_env`/`put_env` in touched files beyond
the existing seam; born manifest's certs verified by effect through
the pod store; create-once on node_id with the false comment gone and
the node_identity.ex cross-reference truthed; divergent-values arm
present in the race test; full core reconciled against 3,438+new;
fence greps (serve node name, live data dir, cert_mint_controller
untouched) both directions.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). bd is a
frozen archive and answers "no issue found" for everything since
2026-08-05. A round that cannot file via the verb reports identities
for the operator, stated as a deviation.

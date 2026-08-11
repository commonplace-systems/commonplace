# S13-fix brief: the GitBridge signs its own presence — CX-vghh's writer gets a principal

> Plan's ruling (msg 11261) on the S13-disc measurement (@386c7cf):
> option ① ratified whole — the BRIDGE-AGENT signs its own presence.
> Basis: presence asserts WHO is present, so the present principal
> signs; the {:presence, identity_uuid} cert machinery exists for
> exactly this write; CX-hk0s already ruled the family (a declared
> process signs its own log, AS ITSELF). Node-signs-for-the-bot was
> REJECTED as the ambient-authority shape the presence model avoids.
> The measured mechanism (docs/notes/2026-08-11-s13-boot-writer-
> measurement.md): GitBridge.Server.safe_create_presence/2 →
> Presence.create/5 (presence doc unsigned-DENIED, root attach
> unsigned-DENIED) → Presence.set_activity/4 (unsigned-DENIED), fresh
> uuid re-minted every boot.

## The ruled fix

1. GitBridge presence init signs AS the bridge-agent identity
   (git-bridge.bot) using its AgentKeys custody + the presence carve —
   composing from shipped parts, no new machinery.
2. ⭐ BOTH unsigned fallbacks die in this round: presence init AND the
   inbound cycle's unsigned fallback. An unsigned-under-permissive
   fallback is how this class survives (the S6 posture family).
3. MISSING KEY = LOUD SKIP with the named reason — LBD-4's own law: a
   principal that cannot provision must NOT appear. Never a quiet
   unsigned write, never an anonymous crash.
4. Boot behavior becomes ATTEMPT-ONCE-THEN-SKIP-LOUDLY — never
   retry-forever. (The measured state was three denials per boot with
   no operator consequence: the denial-counter shape at boot
   frequency.)
5. ⚠️ THE NAMED ROOT-ATTACH CHECK (plan's, mandatory): denial 2 was an
   attach to the WORKSPACE ROOT. Post-S2v4 that write passes the
   root-write policy. NAME where the presence doc attaches and confirm
   the target is policy-compliant: if it is genuinely a substrate root
   entry it belongs in the REGISTERED SET (a dunder name, per the
   going-forward convention); if the root attach was incidental,
   relocate to the presence model's proper home. ⛔ The fix must not
   teach the root policy its first exception — if compliance seems to
   require an exception or an unregistered bare name at root, STOP AND
   REPORT.

## ⛔ Escape hatches, up front

- The root-attach placement question above (stop rather than
  special-case).
- If the bridge-agent identity lacks AgentKeys custody in some
  deployment shape (no minted keypair), the loud-skip arm must cover
  it — but if PROVISIONING a keypair at boot seems needed, stop:
  mint-on-demand is the trap (the sub-agent-identity arc's standing
  warning).

## Tests (red-first — the S13 fixture is your harness)

- The landed boot_writer_measurement_test.exs drives the exact
  denials: extend/sibling it. RED-FIRST is already recorded (three
  denials); after: under enforce with the bridge key present, the
  presence lands SIGNED (verify signer identity by reading the commit
  back), attached at the policy-compliant location, and set_activity
  lands signed — ZERO denials across two boots.
- Missing-key arm: remove/withhold the bridge key → loud skip with the
  named reason, NO write attempted, NO crash, and the skip happens
  ONCE (attempt-once pin — no retry loop).
- Inbound-cycle fallback death: the code path that fell back to
  unsigned now refuses/skips loudly instead (red-first: record the
  current fallback behavior).
- Root-policy arm: the presence attach passes RootWritePolicy for the
  workspace classes that accept it (state which classes and why —
  :minimal presumably refuses bridge presence like all substrate
  names, and that refusal must be a loud skip, not a boot failure).

## Gates

GitBridge + presence + boot-writer test files, then FULL core suite
(mix test apps/commonplace/test) + `mix compile --warnings-as-errors`;
counts reported. Tmp stores only.

## Deliverable

Work left UNCOMMITTED for the operator to land. Report: where the
presence attaches and its policy compliance, red-first/after denial
counts across two boots, the signer verified by commit re-read, loud
-skip texts verbatim, test counts, deviations.

# CX-3xwu (A) — Automatic Presence Reaper: design proposal

**Status:** PROPOSAL for jes's review (NOT built — the one genuinely-hazardous piece of the CX-3xwu family; plan-gated on jes's greenlight). Author: overnight autonomous session 2026-07-13. Reviewer: commonplace-plan.

## Context — what already shipped (the safe pieces)

CX-3xwu's ghost-roster problem has THREE parts. Two shipped autonomously tonight (plan-reviewed), leaving only the continuous reaper (this doc):

- **B-i — new-ghost PREVENTION (shipped, no code needed):** clean-quit retraction already lands under enforce for bot/web/ephemeral sessions — `provision_session_creds` guarantees a `{:presence}` cert, `PlayerSession.terminate/2` signs the retraction. Live-verified (bot `look`→.usr appears, `quit`→.usr gone). So a *clean* disconnect no longer ghosts.
- **B-ii — current-substrate CLEANUP (shipped, one-time ops):** a plan-approved one-time node-signed reap of 15 confirmed-dead `.usr` (dead = no live session backing it; content-discriminator excluded identity records; fail-closed; verified). One-time + self-healing, NOT a standing power.
- **who display FILTER (shipped tonight):** `who` renders a `.usr` IFF a live session backs it (keyed on a filename-keyed `PresenceRegistry` — registration lifetime == session lifetime). Read-only, no mutation, no reap hazard. **This HIDES any ghost — present or future crash-ghost — from the roster regardless of substrate.**

What remains uncovered: a session that **crashes/is killed** (no clean `terminate`) leaves a stale `.usr` in the *substrate* forever. B-ii cleaned the current ones; the who-filter HIDES them; but nothing CONTINUOUSLY GCs new crash-ghosts from the substrate. That is what an automatic reaper would do.

## The hazard (why this is jes-gated, not autonomous)

A continuous, node-signed reaper that MUTATES the world is the **reaper-miss class**: its safety rests entirely on the deadness signal being correct. Unlike B-ii (one-time, bounded, self-healing on a false-reap), a continuous reaper that false-reaps a LIVE player **re-reaps them every cycle = a persistent presence-DoS** (the player keeps re-writing their presence, the reaper keeps removing it). Shipping that unattended overnight could depopulate the world with nobody to catch it.

The classic form — key on heartbeat-staleness (`now − last_heartbeat > threshold`) — has an additional **feedback hazard**: load → delayed heartbeats → staleness crosses the threshold → reap live players; and per-session periodic *signed* heartbeat writes are themselves commit-churn that could *cause* the load (cf. the Bursar persist-ceiling). "Stale = now − last_heartbeat" is an inherently live-time judgment — the least self-contained kind of trust decision.

## The design spine (plan's hard requirement): a live-but-idle/slow player is STRUCTURALLY never reaped

The key realization from building the who-filter: **the `PresenceRegistry` gives EXACT live-session membership, so the reaper needs no heartbeat at all.** A `.usr` with a registered live session is alive by construction; a `.usr` with NO registered session is abandoned. This replaces the fragile "now − last_heartbeat" judgment with a structural one — and it's the SAME signal the who-filter and B-ii already use.

Proposed reaper, IF built:

1. **Deadness = no live session in the registry, NOT heartbeat age.** Reap-candidate = a `.usr` whose `presence_filename` is not in `PresenceRegistry` (no live PlayerSession) — the same content-discriminator as B-ii (presence-shape, exclude identity records), the same fail-closed posture.
2. **Grace period before reap.** A candidate must be unregistered for a generous grace window (e.g. minutes) across ≥2 checks, so a registration race / reconnect blip never triggers a reap.
3. **Cross-node completeness is the real risk.** The registry is per-node/in-process. In a cluster a live session's registration lives on ITS node; a reaper on another node would not see it → false-reap. So a clustered reaper MUST consult a cluster-wide liveness view (pg / a distributed registry) or run only single-node — and fail-CLOSED (skip) on any cross-node uncertainty. On a fresh restart the registry is empty, but a not-yet-reconnected pre-restart player is correctly a ghost (grace period still applies).
4. **Node-signed, scoped, observable, rate-limited.** Node-signed `Presence.remove` of ONLY the `.usr` entry (value-set-diff), each logged with why-dead, a per-cycle cap so a bug can't mass-reap.
5. **Self-healing preserved but NOT relied upon.** A live session re-writes on next action — but for a *continuous* reaper that is the DoS vector, not a backstop, so correctness (never reap a live registration) must hold structurally, not lean on re-write.

## Recommendation

**Consider NOT building the continuous reaper at all** — the shipped who-FILTER already makes the roster fully clean (ghosts hidden regardless of substrate), and stale substrate `.usr` entries are harmless if never displayed. Periodic one-time B-ii-style cleanups (operator-run, dry-run-reviewed) can GC substrate accumulation on demand without a standing hazardous power. This trades a small amount of dead substrate for eliminating the reap-the-living risk class entirely.

IF a continuous reaper is still wanted (e.g. substrate growth becomes a real cost), build it on the registry-keyed spine above (live-session membership + grace + cross-node fail-closed + node-signed + observable + capped), NOT on heartbeat-staleness — and pin the load-bearing property: **a live-but-idle/slow session (live registration, arbitrarily old heartbeat) is NEVER a reap candidate** (the who-filter's PIN 2, applied to the mutation path). That pin is hard to make non-vacuous (needs simulated live-slow sessions under load) — which is itself evidence this belongs to a reviewed design session, not an autonomous build.

## Plan's review (commonplace-plan, 2026-07-13) — STRONGLY ENDORSES "don't build it"

- The display-filter already delivers the continuous reaper's VALUE (a clean roster, robust to future crash-ghosts) with ZERO mutation → the continuous reaper is largely **redundant**, and it carries the worst hazard in the system.
- The Registry-eliminates-heartbeat insight is good and kills the staleness-feedback loop — BUT push it one step: even a Registry-keyed reaper still MUTATES, so a registration **false-read** (a live session whose `register` failed at init → looks unregistered) → the reaper removes a LIVE player's `.usr`, and it self-heals **only if the session RE-WRITES presence**. If presence is written once at init and not re-written, a reaped live session stays unpresenced — no self-heal. So a Registry-keyed reaper *shrinks* the hazard but does not eliminate it. ⇒ **"don't build it" > "build a safer one"**: the display-filter makes it unnecessary; don't take on the residual mutation-hazard for a redundant cleaner.
- Substrate hygiene via periodic B-ii-style cleanups is right, WITH one condition: keep them **operator-triggered** (a human eyeballs each dry-run before it writes — exactly the loop that caught `jes.usr` tonight), **NOT scheduled-automatic**. A scheduled-automatic cleanup reaps without a per-run human review → a systematic dead-verification bug would reap a batch each run (fail-closed + self-healing shrink it, but no eyeball). If jes ever wants it automatic, THAT design needs its own careful review (the dry-run becomes log-and-alert, fail-closed hard, bounded per-run).

**NET for jes (plan-endorsed): ship the display-filter (done) + operator-triggered periodic B-ii cleanups for substrate hygiene + DON'T build the continuous auto-reaper.** This eliminates the reap-the-living class entirely — the right end-state.

## Related

- Display-side complement: the who-filter (shipped). CX-jiyi (MCP agent-freshness presence) + CX-9rd3 (unified cap-provisioning) — the agent-presence half, separately jes-gated. CX-ll5d (cert-less-durable convergence). This proposal is the substrate-side continuous-GC piece; it is the only one with the reap-the-living hazard.

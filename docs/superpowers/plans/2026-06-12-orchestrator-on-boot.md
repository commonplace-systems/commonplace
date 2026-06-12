# Orchestrator-on-Boot Implementation Plan (move #2, CX-tdkq.12)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. (This run: SERIAL inline execution per boss directive.)

**Goal:** Supervise `Commonplace.Process.Orchestrator` so the malleable-software engine survives crashes and runs on boot in opted-in contexts — closing the on-boot half of the trust story the gates were built for, fail-closed.

**Architecture:** Four pieces. (0) **Fail-closed trust config** — a corrupt trust.json currently degrades to the permissive default; absent stays permissive, corrupt must reject-all. (1) **Restart correctness** — managed processes are unnamed+unlinked by design, so a restarted orchestrator would duplicate them; the existing `orchestrator_status.json` (already written every reconcile, already the cross-BEAM orphan mechanism) gains a `beam_pid` field and becomes the SINGLE sweep source: sweep-on-init kills the prior generation (BEAM pids intra-VM, OS-pid trees + sandbox dirs cross-VM), then reconciles fresh. (2) **Supervision** — `orchestrator_children()` double-gated on opt-in config AND resolvable workspace root; named child; `:workspace` root sentinel resolved at init; loud warning when enabled in a permissive workspace. (3) **serve.ex reconcile** — supervised `start_child` replaces the bare `start_link` (cli/serve.ex:54).

**Tech Stack:** Elixir/OTP. Gate B and reconcile semantics unchanged — `parse_processes_doc` (orchestrator.ex:522) already gates every declaration (incl. `:sandbox_exec`) on every pass.

**Beads:** CX-tdkq.12. Follow-ups to relay: hot-adopt-on-restart (P3), per-tick root re-resolution (P3), `:secrets` capability caveat (P3), mint-time warning for write-without-execute certs on code docs (alongside CX-tdkq.27).

---

## Decisions ledger (converged with commonplace-plan, msgs 5126/5128/5130/5131)

| # | Decision | Resolution |
|---|---|---|
| O1 | Restart correctness: sweep vs adopt? | **Sweep-on-init from `orchestrator_status.json`** (gains `beam_pid`): kill prior generation — `list_to_pid` + alive-check intra-VM, `kill_process_tree(os_pid)` + sandbox-dir cleanup cross-VM — then reconcile fresh. ONE file-backed mechanism for both crash kinds; no new Ledger process. Hot adopt-in-place = follow-up. |
| O2 | Boot policy | Explicit opt-in `config :commonplace, :orchestrator_on_boot, true` AND `Workspace.root_uuid()` resolvable; default **false**. Web/CLI-one-shot/test/mcp/bots never auto-run unless configured. `serve` turns it on. |
| O3 | Naming | Supervised spec passes `name: Orchestrator`; `start_link/1` unnamed-by-default (test compat). |
| O4 | Root resolution | Spec passes `root_uuid: :workspace`; `init/1` resolves via `Workspace.root_uuid()`, `{:stop, :no_workspace_root}` if absent. Per-tick re-resolution deferred. |
| O5 | serve.ex | Keeps pre-steps; `Supervisor.start_child(Commonplace.Supervisor, spec)` guarded by `Process.whereis(Orchestrator)`. `kill_managed_orphans` becomes redundant with sweep (sweep runs on every orchestrator start) — serve keeps `kill_orchestrator_orphan` (prior serve's own OS pid). |
| O6 | Fail-closed trust config (commonplace-plan's boot-order point, grounded) | No load-step exists — `Trust.config/0` is lazy per check, so there is no permissive boot WINDOW. The real hole: `config_from_file` returns nil on corrupt JSON → permissive default. Fix: ABSENT file → permissive default (intended zero-config); PRESENT-but-unreadable/unparseable → **fail closed** (`accept_unsigned: false`, no pins — reject everything) + loud error log. |
| O7 | Permissive + opt-in foot-gun | Don't refuse (single-operator serve is legitimate); emit a LOUD startup warning when orchestrator-on-boot is enabled and the effective trust config is fully permissive. |
| O8 | Declaration gating (commonplace-plan's #1) | Already wired — `parse_processes_doc` (orchestrator.ex:522) runs `authorized_to_execute?` on every `__processes.json` on every reconcile; explicitly "the only gate on :sandbox_exec"; config-shrink convergence stops revoked processes; $secret resolution is transitively gated. NO new gate needed; restart test asserts it survives the refactor. |
| O9 | CX-tdkq.27 consistency (commonplace-plan refinement A) | The reconcile gate shares the execute-baseline exposure: a `__processes.json` is a regular doc, so a write-only peer's declaration edit absorbed into a node-signed snapshot would launder past `authorized_to_execute?` (walk halts at the baseline) → process runs. CX-tdkq.27's fix (execute-clean snapshot baseline) closes this for declarations too; the interim v1 delegation policy extends to "…and on docs containing process declarations" (mint-time enforcement bead being filed by commonplace-plan). Latent-until-phase-3, conscious, NOT move-#2-blocking. |

## File structure

- Modify: `apps/commonplace/lib/commonplace/trust.ex` (`config_from_file` fail-closed split)
- Modify: `apps/commonplace/lib/commonplace/process/orchestrator.ex` (status file `beam_pid`; sweep-on-init; `:workspace` sentinel; permissive warning)
- Modify: `apps/commonplace/lib/commonplace/application.ex` (`orchestrator_children()`)
- Modify: `apps/commonplace_cli/lib/commonplace/cli/serve.ex:49-60` (supervised start; drop `kill_managed_orphans` call)
- Test: `apps/commonplace/test/commonplace/trust_config_fail_closed_test.exs` (new)
- Test: `apps/commonplace/test/commonplace/process/orchestrator_restart_test.exs` (new — the meat)
- Test: `apps/commonplace/test/commonplace/application_orchestrator_gating_test.exs` (new, small)

---

## Task 0: fail-closed trust config

- [ ] Failing tests: (a) no trust.json → `Trust.config()` permissive default (existing behavior pinned); (b) corrupt trust.json (`"{not json"`) → `accept_unsigned: false` and `trusted_identities: %{}` (+ node auto-trust still folds in — system commits keep working, nothing else does); (c) valid strict file → parsed as today.
- [ ] Implement: `config_from_file` returns `{:ok, cfg} | :absent | {:error, reason}`; `config/0` maps `:absent` → default, `{:error, _}` → fail-closed config + `Logger.error`.
- [ ] Run trust suite; commit `CX-tdkq.12(0): corrupt trust.json fails CLOSED, not open`.

## Task 1: status file gains `beam_pid`

- [ ] Failing test: after a managed `:elixir` process starts, `orchestrator_status.json` entry carries a parseable `beam_pid` whose process is alive.
- [ ] Implement: `write_status_file` adds `"beam_pid" => inspect(proc.pid)`.
- [ ] Green; commit `CX-tdkq.12(i): status file records beam_pid — sweep source for intra-VM generations`.

## Task 2: sweep-on-init (the meat)

- [ ] Failing tests (`orchestrator_restart_test.exs`, crib fixtures from `orchestrator_trust_gate_test.exs`): (a) orchestrator A runs declared process P1; `Process.exit(orchA, :kill)`; orchestrator B starts on same data_dir/root → P1 is dead and exactly ONE instance of the declaration runs; (b) sweep tolerates stale/dead entries and a missing status file; (c) declaration gating still enforced post-restart (untrusted declaration contributes nothing — pins O8).
- [ ] Implement `sweep_prior_generation/1` in orchestrator `init/1` before the first tick: read status file → per entry: `beam_pid` → `list_to_pid` (rescue) → if alive, `GenServer.stop(pid, :shutdown, grace)` (fallback `Process.exit(pid, :kill)`); `os_pid` → port the `kill_process_tree` walk from serve.ex into core (shared helper, serve delegates); `sandbox_dir` → cleanup. Then remove the file and reconcile fresh. One summary log line.
- [ ] Green incl. the whole `process/` dir; commit `CX-tdkq.12(ii): sweep-on-init — restart converges instead of duplicating`.

## Task 3: supervision wiring

- [ ] Failing tests (`application_orchestrator_gating_test.exs`): flag+root → named spec from `orchestrator_children()`; flag false → `[]`; flag true, no root → `[]`; `root_uuid: :workspace` resolves in init; enabled+permissive-config → `Logger.warning` emitted (capture_log).
- [ ] Implement: `:workspace` sentinel in `init/1`; `orchestrator_children/0` (reaper-pattern double-gating); permissive-posture warning at init.
- [ ] Green; commit `CX-tdkq.12(iii): orchestrator_on_boot — opt-in supervised child, workspace-gated, permissive-posture warning`.

## Task 4: serve.ex reconcile + full verification

- [ ] serve.ex: keep `kill_orchestrator_orphan` + disk-import; drop the now-redundant `kill_managed_orphans` call (sweep owns it); replace bare `start_link` with whereis-guarded `Supervisor.start_child`; call sites use the name.
- [ ] CLI suite + full core/web/mcp verification (`--warnings-as-errors`; pipe-hang guard for background runs).
- [ ] Commit `CX-tdkq.12(iv): serve uses the supervised orchestrator — bare start_link retired`.

## Task 5: live proof

- [ ] Scratch workspace, flag on, declared process running → kill the orchestrator GenServer → supervisor restarts → log shows sweep (prior gen reaped) + re-reconcile (process back, exactly one). Transcript into the bead close. No demo/ dir — the log is the proof.

## What this plan does NOT do
- No hot-adopt, no per-tick root re-resolution, no `:secrets` caveat (follow-up beads).
- No change to Gate B/reconcile semantics or process isolation (unlinked stays unlinked).
- No default-on anywhere.

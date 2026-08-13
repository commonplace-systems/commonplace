# Runner worker-launch build brief — CX-n6zc

> **The work's ticket is CX-n6zc.** Context labels, none the citation:
> CX-gkxa built `Runner.Provisioner` and deliberately did NOT execute the
> sandbox it constructs; CX-vtaa tightened the build sandbox hours ago and
> changes what this round can verify from inside; CX-d59r added the birth
> mint. This round gives `Provisioner` its **first production caller**,
> which is why every hazard below has been theoretical until now and
> stops being so the moment this lands.
>
> ⛔ **THIS IS THE FIRST ROUND THAT EXECUTES A SANDBOX AND KILLS PROCESS
> SCOPES ON A HOST RUNNING LIVE MONEY.** `hermes` is a BEAM holding a
> real position. Its safety is not a background concern of this round —
> it is the round's acceptance criterion.

## The four ratified gates

Plan ratified these from the operator's host-safety input. They are
requirements, not guidance.

1. **The reaping story ships in THIS round.** A pod that can be started
   and not reliably stopped is not a feature with a follow-up; it is a
   leak with a demo.
2. ⛔ **A pod must be killable AS A UNIT, WITHOUT NAMING A PATTERN.**
   Every `pkill -f` selector on this host also matches hermes. This is
   not hypothetical: a `grep -E 'phx.server' | kill` took down the live
   serve *and* hermes on 2026-08-11, and the self-matching variant cost
   about two hours across three incidents on 2026-08-12. ⇒ **The kill
   must address a scope/cgroup/handle, never a name or an argv
   substring.** If your design needs a pattern to find what to kill, the
   design is wrong.
3. **The kill must be DEMONSTRATED**, not asserted — see the split
   below, which is what makes this gate real.
4. ⚠️ **Where pods are launched from is a safety property.**
   `OOMPolicy=stop` kills the entire scope, and services inherit their
   launcher's. A pod launched from the wrong parent takes its parent
   down with it under memory pressure. State where pods are launched
   from and why that parent is safe.

## ⭐ The demonstration splits across the fence — and that is the point

CX-vtaa tightened the build sandbox to `--unshare-pid --proc /proc`
hours ago. Measured consequence: **`systemctl --user` fails inside it
("Failed to connect to bus"), and hermes is neither visible nor
signallable** (verified against its real MainPID: no such process,
`/proc/<pid>` absent).

⇒ **You cannot read hermes' `ActiveState`, and you must not try.** The
demonstration is therefore two-party:

- **You (in the sandbox)**: start a pod, kill its scope as a unit, and
  report exactly what you ran and what you observed *within your own
  namespace* — the pod's processes gone, the handle released.
- **The operator (outside the fence)**: reads hermes' `ActiveState`
  **before and after** and states both. That is the positive control,
  and it is assigned to a party who is not the one doing the killing.

⭐ **This is the gate becoming honest rather than breaking.** Before the
fence change, the agent performing the kill could also have observed —
and therefore falsified — its own control. Now it structurally cannot.
**The party performing a destructive act cannot verify its own blast
radius, so verification lives outside the actor** — the same shape as
this week's three-party pushes.

⛔ **Do not work around your inability to see hermes.** It is a fence
working, not a defect: report what you can observe and let the control
be someone else's.

## The seam this round owes by name

`provisioner.ex`'s moduledoc says, in the tree, that *"the worker-launch
round replaces this seam."* **This is that round.**
`with_workspace_env/2` temporarily repoints **node-global**
`:commonplace` application env (`:data_dir`, `:trust`, both gates) at
the pod store during birth, because trust resolution and the root-write
policy read config rather than taking a store argument. On a node
serving a live workspace, concurrent operations during that window read
the pod's store.

⇒ That was harmless while `Provisioner` had zero callers. **This round
creates the caller.** Either replace the seam or state precisely why a
runner process hosting births is safe without replacing it — and if the
honest answer is that it needs machinery beyond this round, **say so and
stop**, rather than shipping a caller that makes a documented hazard
reachable. ⚠️ If you do replace it, the moduledoc paragraph must be
truthed in the same commit; a stale promise is worse than an open one.

## ⛔ Escape hatches, up front

- ⛔ **No `pkill`, `killall`, or any pattern-matched signal, anywhere** —
  not in the implementation, not in a test, not in a scratch command.
  Kill by captured handle or scope only.
- ⛔ **Nothing that touches hermes, the live serve, or their scopes.** If
  a step seems to require it, STOP.
- ⛔ **Do not modify the build sandbox's own fence** (`sol-egress-run.sh`
  or its masks). That fence contains you; changing it from inside is the
  shape we have refused twice this week.
- If a pod cannot be reliably reaped by the mechanism you chose, that is
  a **finding, and the round stops there** — an unreapable pod is worse
  than no pod.
- Telemetry events in scope: NONE beyond what reaping needs.

## Tests

Baseline: full core **3,449 / 0 failures / 1 skipped** at
`apps/commonplace/test`; umbrella **4,137 across 5 apps**.
⚠️ Run per-app — multi-app `mix test` paths silently drop tests here.

- **Launch**: a pod provisioned from a fixture manifest/profile actually
  runs its invocation; assert by effect (something the pod did), not by
  the absence of an error.
- ⭐ **Reap, demonstrated**: start a pod, kill it as a unit, and prove
  the processes are gone **by handle**, with a control showing the same
  check would have found them while alive. A reap test that has never
  seen a live pod proves nothing.
- **No-pattern pin**: assert by construction that the kill path contains
  no name/argv matching — state how you checked, with a control that the
  grep would find such a call if present.
- **Isolation pin**: the executed invocation carries `--unshare-all` and
  the six masks; a pod cannot see the host process table.

## Review criteria

Reaping shipped and demonstrated by handle with a live-pod control; zero
pattern-matched signals anywhere in the diff (grep with control); the
launch parent stated with its OOM reasoning; the split demonstration
reported honestly, with the operator's hermes before/after attached at
review rather than claimed by the round; the `with_workspace_env` seam
either replaced with its moduledoc truthed, or its continued presence
justified in writing; counts reconciled per-app.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). ⚠️ **The verb
is unreachable from inside the sandbox — a capability boundary, not a
defect and not a deviation.** Report identities; the reviewer files them.

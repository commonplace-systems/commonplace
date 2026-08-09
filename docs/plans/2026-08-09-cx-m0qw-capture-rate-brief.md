# BUILD BRIEF — CX-m0qw part 1: make the audit path able to report its own capture rate

**Ticket:** **CX-m0qw** (p1) — this brief is the **gating piece only**, not the
mechanism hunt.
**Why first:** every existing instrument sits **downstream of the drop**, so no
hypothesis about the loss is testable until an independent denominator exists.

---

## 0. Environment contract (standing)

Named worktree off current `origin/main`; ⛔ git metadata read-only, **leave
changes UNSTAGED**, no `git add`, no commit; ⛔ no serve/store route — build
fixture stores; suites via `bin/cp-test-guard`, **one at a time**; ⚠️ rc from
the command itself, never a pipe; ⚠️ **run suites in the FOREGROUND redirected
to a file and read the file — each `exec` gets a fresh PID namespace, so
`ps`/`pgrep` can never see a process started by a previous command.**

## 1. ⛔ THE PROBLEM, STATED AS THE THING THAT MUST BECOME MEASURABLE

Measured on boot `436abd78f6e73c54`: **148,647 denial log lines, 5 organic
audit records. A 0.003% capture rate that no instrument in the system could
report.**

`AuditDispatcher.status/0` read a clean **155/155 offered/recorded** while this
was true, and it was not lying. Its identity is

    offered == recorded + shed + failed + guarded + queued + in_flight

⇒ ⭐ **`offered` is incremented BY THE DISPATCHER. Anything dropped before the
cast never enters the identity at all.** The module's anti-underreport
denominator — built precisely because *"an audit stream that can lose events
silently is the silent-underreport pattern auditing itself"* — **is blind to
exactly one failure: loss upstream of its own counter.** The denominator was
honest about everything it could see. The loss was outside it.

⇒ **THE DENOMINATOR MUST BE BUILT FROM WHAT ARRIVED, NOT FROM WHAT SURVIVED.**

## 2. The change

At the denial emission site — `handle_local_write_denial/3`, commit_store.ex
:2341 (`:dry_run`) and :2357 (`:enforce`) — increment a **counter that shares
no failure mode with the telemetry path**, adjacent to the `Logger.warning`
and **before** the `:telemetry.execute`.

⭐ **Why this position is the whole design:** the counter must be incremented
by the code that *decides the denial*, not by anything that *observes* it. An
`:atomics`/`:counters` increment in that function cannot be detached (it is not
a telemetry handler), cannot be shed (it is not queued), cannot be rate-limited
(it is not a record), and cannot be refused (it is not a write). ⇒ **It is the
only quantity in the system that equals the number of denials that actually
happened.**

Then expose the ratio. Suggested shape — **you may choose another, but it must
satisfy §3**:

    Trust.capture_rate() ->
      %{emitted: <independent counter>,       # what ARRIVED
        recorded: <AuditDispatcher recorded>, # what SURVIVED
        offered:  <AuditDispatcher offered>,
        upstream_loss: emitted - offered,     # ⭐ THE NEW NUMBER. Was 148,642.
        boot_id: ...}

⭐ **`upstream_loss` is the entire point of the ticket.** It is the quantity
that was 148,642 and that nothing could name.

## 2b. ⛔ THE COUNTER IS PER-BOOT, AND THAT MUST BE VISIBLE IN ITS OUTPUT

`:atomics`/`:counters` **reset on restart.** ⇒ `upstream_loss` measures loss
**within a boot** and can say nothing whatever about a previous one.

⛔ **So this fixes detection GOING FORWARD and cannot recover the 148,642.**
And the dangerous reading is the reverse one: **a future reader seeing
`upstream_loss == 0` must not take it as "no loss has ever occurred."**

⚠️ ⭐ **This is the SAME as-of trap that produced the `155/155` reading, one
layer up — and it will be MORE tempting here, because this is the counter
everyone will have been told to trust.**

⇒ **REQUIRED: report `boot_id` alongside every figure**, exactly as the audit
records already do, so **the number carries its enclosure by construction
rather than by discipline.** That is this investigation's own scope law applied
to the instrument built to enforce it, and it costs one field.

⚠️ **`accounted?/1` must be extended or it becomes a false green:** the
existing identity will still balance while `upstream_loss` is enormous, so a
caller checking `accounted?/1` alone would read healthy. Either fold `emitted`
into the identity or make `accounted?/1` refuse to answer without it.

## 3. ⛔ ACCEPTANCE — the control must go red UNDER THE CONDITION THAT WAS MISSED

1. ⭐ **RED FIRST, AND IT IS THE TICKET:** a test that **detaches the audit
   handler**, drives N denials, and asserts `upstream_loss == N`.
   **Demonstrate it against today's code first** — today there is no number to
   assert on, which is the defect.
2. ⭐ **A SECOND RED, DIFFERENT CAUSE:** drive denials **past the rate-limiter
   cap** (`@cap 20` / `@window_ms 60_000`) and show the loss is visible.
   ⛔ Two causes, because a check validated against one drop path is a check
   for that path, not for capture rate.
3. ⛔ **THE GREEN MUST BE ABLE TO BE GREEN:** a normal run shows
   `upstream_loss == 0`. A metric that is never zero is not a metric.
4. ⚠️ **The counter must survive what the audit path does not.** Prove it: in
   the same test where the handler is detached, assert the counter still
   advanced. **That is the independence claim, and an untested independence
   claim is the defect this ticket is about.**
5. ⛔ **DO NOT wire this into AuditCanary in this brief.** The canary's
   redesign (probe frequency must share the fate of the traffic it certifies)
   is a separate decision. **Build the instrument; do not also change the thing
   that will consume it.**
6. `mix compile --warnings-as-errors` rc=0. Named suites with counts,
   baselined on main first, one at a time:
   - `apps/commonplace/test/commonplace/trust`
   - `apps/commonplace/test/commonplace/store`
7. **Name anything you could not verify in-sandbox** and stop rather than
   approximating. ⚠️ You have no serve, no store route, no erlang cookie, and
   the node signing key is a 0-byte file — use fixture signing contexts.

## 4. ⚠️ Things that look like this ticket and are not

- **Explaining the 0.003%.** Out of scope. This brief builds the instrument
  that makes explanations testable. ⛔ **Do not fix a mechanism you think you
  found; report it.**
- **The nine `:calling_self` handler detaches**, and `recursion_guard/1` being
  keyed on the doc when the recursion is by process — **separate ticket.**
- **The sync layer's 12 unsigned write sites** — separate census, and it must
  be sized on its own measurements.

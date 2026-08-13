# Pod channel-fence: make the acceptance test actually run — CX-n6zc / CX-7fxm / CX-vc0q

> ⛔ **THE FENCE IS CORRECT AND IS NOT THIS ROUND'S SUBJECT.** Verified by
> capability, independently of any test, inside the pod's exact repaired
> mask set: live channels reachable **0** (host: 23) · `relay.sock`
> **unreachable** · `S.gpg-agent.ssh` **unreachable** · tmux panes **0** ·
> squad queue **absent** (host: 13,549,568 bytes) · `.ssh` **0 entries**.
> ⇒ **Do not touch `provisioner.ex`, `launcher.ex` or `pod_handle.ex`.**
> Ten files are already reviewed and hash-pinned; they must stay
> byte-identical.
>
> ⭐⭐ **THIS ROUND EXISTS BECAUSE THE TEST THAT ASSERTS THE FENCE HAS
> NEVER PASSED — through three rounds of channel work, all of which were
> verified by reading the diff.** The reviewer proved the defect predates
> any reviewer patch by reverting to the original worker script in a
> copy and observing the identical failure.

## The two defects, in the order they must be fixed

### ① The internal budget exceeds its enclosing timeout — so it is unreachable

`launcher_test.exs:135` waits `System.monotonic_time(:millisecond) +
180_000` for the worker's output. **ExUnit's default test timeout is
60_000.** ⇒ The outer limit preempts the inner one every time, and the
failure surfaces as `ExUnit.TimeoutError` — **which reads as a hang
rather than as a wait that ran out.**

⭐ **A budget that exceeds its enclosing timeout is not a budget, it is a
comment.**

### ② The worker never produces its file — and ① was hiding it

With `--timeout 300000` the test ran the **full 180 seconds** and still
failed. ⇒ **Not load, not a budget: the file never appears.** Both worker
scripts are committed (`git add` at line 63 includes
`channel-worker.sh`), so the cause is downstream of that.

⚠️ **Diagnose this one; do not size around it.** The enabling fix for ①
is only to make ②'s failure legible.

## ⛔ The budget comes DOWN, not the timeout up

Measured on the host: the enumeration walks **45,772 paths** under a
7.5G `/tmp` and completes in **0.129 seconds**, returning 23 channels.

⇒ **180s is ~1400× the real cost.** That is not a slow-operation
allowance — **it is a number written around an undiagnosed hang.** Had it
been 5s, defect ① would never have existed and ② would have surfaced
three rounds ago as a fast, clean failure.

⛔ **So: fix the worker, then size the budget to the measurement** — a
couple of seconds with margin — and set `@tag timeout:` only as high as
that requires. **Raising the ExUnit timeout to 180s+ would make the test
legal while preserving a three-minute stall on every future CI run for
an operation that costs 0.13s.** ⚠️ Sizing a budget around an
undiagnosed hang is exactly how this evening's load-versus-budget
confusion started.

## What "done" means

- The channel test **executes and passes**, with its assertions
  unchanged — they are already correct, including the status capture
  that records `find`'s own count rather than a pipeline's exit status.
- ⭐ **The host/pod pair is asserted in both directions**: non-zero on
  the host, **0** inside the pod. An enumeration returning 0 in both
  places proves nothing.
- ⚠️ **Discriminate on the socket and the entry count, never on the
  directory.** `test -d /tmp/claude-chat` **succeeds inside a correctly
  fenced pod** — the tmpfs makes it empty, not missing. The directory
  was never the property.
- The budget reflects the measurement, and the `@tag timeout:` is sized
  to the budget rather than to a guess.

## ⛔ Escape hatches, up front

- ⛔ **Do not modify the fence.** `provisioner.ex`, `launcher.ex`,
  `pod_handle.ex` and the other seven protected files stay
  byte-identical; they will be hash-checked.
- ⛔ **Do not weaken or rewrite the assertions to get green.** If an
  assertion is wrong, that is a finding — report it and stop.
- ⛔ **Do not re-derive the channel list.** Your vantage point cannot see
  it: a `0` result means MASKED, not ABSENT. The list is supplied data.
- If the worker's silence turns out to require a fence change, **STOP
  AND REPORT** — that is a different round with a different review.

## Review criteria

The test runs and passes with assertions unmodified; the budget is
justified by a stated measurement rather than a round number; the
`@tag timeout:` is sized to the budget; the host/pod pair asserted both
directions; the ten protected files hash-identical; and the reason the
worker was silent stated plainly in the report, because **that
explanation is the round's real product** — the fix is downstream of it.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). ⚠️ Not
reachable from inside the sandbox — a capability boundary, not a defect.
Report identities; the reviewer files them.

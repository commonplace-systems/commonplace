# CX-7fxm + CX-n6zc rework: fence the pod's environment and its channels

> **The work's tickets are CX-7fxm (the defect) and CX-n6zc (the round it
> blocks).** CX-n6zc's mechanism is SOUND and must survive: the
> node-global seam is genuinely removed and propagates through the four
> config readers, reaping is real, the kill goes by captured pid, and the
> handle test proves the unforgeable-ref property in both directions.
> ⛔ **Do not redesign any of that.** This round fixes one thing: what the
> pod inherits.
>
> ⛔⛔ **THE DEFECT, DEMONSTRATED:** `Launcher.open_pod/2` calls
> `Port.open({:spawn_executable, bwrap}, [..., {:args, argv}])` with **no
> `:env`** (launcher.ex:153). Erlang inherits the emulator's environment
> when `:env` is absent. Probe: the same argv with `FAKE_API_KEY` set
> printed `POD_SEES=sk-secret-would-leak` **from inside the sandbox,
> while the `.ssh` tmpfs mask held in the same run.** ⇒ **The six masks
> fence the FILESYSTEM and the environment walks straight through.**

## ⭐ The law this round exists to encode: TEST THE CAPABILITY, NEVER THE HANDLE

Three fixes in four hours each passed the obvious check while leaving the
capability intact:

| fix | obvious check it passed | check that would have caught it |
|---|---|---|
| `--unshare-pid` alone | `kill` blocked | `ls /proc` — 230 host pids still readable |
| env allowlist alone | `echo $TMUX` empty | `tmux list-panes -a` — every pane still listed |
| the six file masks | `.ssh` empty | a parent env var printed from inside |

⚠️ **An empty variable is exactly what a successful fix looks like.** The
obvious verification and the real one differ, and the obvious one is what
you reach for *because you just wrote the fix*.

⇒ **Every acceptance check below is an ATTEMPTED CAPABILITY that must
FAIL, never an inspection of a pointer.**

## What to build

1. **An explicitly constructed pod environment — ALLOWLIST, NEVER
   DENYLIST.** Pass `:env` to `Port.open` built from nothing, containing
   only what the worker legitimately needs. ⛔ A denylist fails on the
   first variable nobody listed — **and the items nobody lists are the
   ones nobody CLASSIFIED as belonging to the list.** That is not
   theoretical: the operator's own wrapper carried
   `env -u LETTA_API_KEY -u SQUAD_ALERTS_PUBLISHER_TOKEN`, a denylist of
   two, and what crossed it was not a secret at all (below).
2. ⭐⭐ **A LIVE-CHANNEL INVENTORY, WHICH IS THE HALF A SECRETS REVIEW
   MISSES.** The worst thing found tonight was not a credential: the
   build sandbox inherited `TMUX`/`TMUX_PANE` and
   `CLAUDE_CODE_MESSAGING_SOCKET`, and `tmux list-panes -a` listed every
   pane on the box — **i.e. `send-keys` into a live-money trading
   session. A signal can kill it; a keystroke can make it trade.**
   ⇒ Ask **"what can reach another running process from here?"**, not
   "what here is a secret?" Inventory sockets, multiplexer handles, IPC
   paths, agent message buses — and mask them in `sandbox_spec/2`
   alongside the six credential masks, **constructed in, with no
   argument to omit them**, exactly as the existing six are.
   ⚠️ Unsetting the variable is NOT sufficient: tmux falls back to its
   default socket path. The socket itself must be masked.
3. **Fix the fixture's ambient dependency.** `launcher_test.exs`'s worker
   writes to `$COMMONPLACE_DATA_DIR`, which **nothing in `runner/`
   sets** — so it passes only when the developer's shell happens to
   define it. Set it explicitly in the constructed env. ⇒ **A test that
   depends on the developer's environment is a test whose result is
   about the developer.**

## Tests — every one an attempted capability

- ⭐ **Canary, demonstrated RED**: the test process sets a canary
  variable **itself** (`System.put_env`), launches a pod, and asserts the
  pod **cannot see it**. ⚠️ **The test must set its own canary rather
  than rely on an ambient secret** — the build sandbox's env is now
  allowlisted, so a canary drawn from ambient state would pass
  vacuously in a world that is already clean. Show it red by
  temporarily restoring inheritance.
- ⭐ **Channel capability**: from inside a pod, `tmux list-panes -a` and
  any messaging-socket access must **fail**. Assert on the attempt's
  failure, not on an unset variable.
- **The worker still works**: the effect file appears because the env
  the pod needs was explicitly supplied — with the count of variables
  asserted, so a future widening is visible.
- **Everything CX-n6zc proved stays proved**: the handle/wrong-handle
  pair, the reap, the no-pattern pin (now scanning all of `runner/`).

## ⛔ Escape hatches, up front

- ⛔ **No `pkill`/`killall`/pattern selectors** — unchanged from CX-n6zc.
- ⛔ **Do not modify the build sandbox's own fence** (`sol-egress-run.sh`).
  It contains you; it was hardened twice tonight and is not this round's
  subject.
- ⚠️ **The build sandbox no longer provides an ambient shell.** Its env is
  23 allowlisted variables; `systemctl --user` fails; ~5 pids visible.
  **If this round needs a variable, NAME IT IN THE REPORT rather than
  working around its absence** — the operator will add it if legitimate.
  `MIX_HOME`/`HEX_HOME`/`MIX_DEPS_PATH`/`MIX_BUILD_PATH` are not
  provided; set them under `/tmp` yourself as previous rounds did.
- If masking a channel breaks the worker, that is a **finding** — report
  which channel and why it was needed; do not unmask to get green.

## Review criteria

`Port.open` receives an explicitly constructed `:env`; it is an allowlist
built from empty, not a filtered inherit; live channels masked in
`sandbox_spec/2` as constructed data with no omit-argument; the canary
test demonstrated red; channel checks assert a **failed attempt**; the
fixture no longer reads an unset ambient variable; CX-n6zc's mechanism
untouched and its tests still green; counts reconciled per-app.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). ⚠️ **Not
reachable from inside the sandbox — a capability boundary, not a defect.**
Report identities; the reviewer files them.

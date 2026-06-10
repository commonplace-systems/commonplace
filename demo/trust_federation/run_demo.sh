#!/usr/bin/env bash
# Live two-node federation trust demo (CX-tdkq.1/.2/.24).
#
# Brings up two REAL BEAM nodes from the commonplace umbrella:
#   - Node B (cpb): a permissive peer holding signed + unsigned + unsigned-code commits.
#   - Node A (cpa): a STRICT node (accept_unsigned: false) that pulls B's
#     commits over the real Commonplace.Sync.NodeSync.catch_up path and
#     enforces Gate A (import) and Gate B (execute).
#
# Run from the repo root:  bash demo/trust_federation/run_demo.sh
#
# Proves: an untrusted commit/code arriving over the sync/import path is
# rejected by the strict node. (NOT a claim about cookie-holding cluster
# members — a BEAM cluster is one trust domain by design.)
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

COOKIE="trustdemo$$"
SHARED="$(mktemp -d /tmp/cp_fed_demo.XXXXXX)"
DIR_A="$SHARED/nodeA/.commonplace"
DIR_B="$SHARED/nodeB/.commonplace"
mkdir -p "$DIR_A" "$DIR_B"

echo "=== epmd ==="
epmd -daemon 2>/dev/null || true
sleep 1
# Clear any stale demo nodes from a prior run (same shortnames).
pkill -f "sname cpb" 2>/dev/null || true
pkill -f "sname cpa" 2>/dev/null || true
sleep 1

SESSION_LOG="${SESSION_LOG:-/tmp/cp_fed_session.log}"
cleanup() {
  pkill -f "sname cpb --cookie $COOKIE" 2>/dev/null || true
  pkill -f "sname cpa --cookie $COOKIE" 2>/dev/null || true
  rm -rf "$SHARED"
}
trap cleanup EXIT

echo "=== launching Node B (peer) ==="
# setsid + closed stdin fully detaches B so it never holds this script's
# stdout pipe open (otherwise the wrapper waits forever for EOF).
setsid elixir --sname cpb --cookie "$COOKIE" -S mix run --no-start demo/trust_federation/node_b.exs "$DIR_B" "$SHARED" \
  > "$SHARED/b.log" 2>&1 < /dev/null &
B_PID=$!
disown 2>/dev/null || true

# Wait for B to author + write its manifest.
for _ in $(seq 1 120); do
  [ -f "$SHARED/b_ready" ] && break
  sleep 0.5
done
if [ ! -f "$SHARED/b_ready" ]; then
  echo "Node B failed to come up. Log:"; cat "$SHARED/b.log"; exit 1
fi
grep -h "\[B\]" "$SHARED/b.log" || true

echo "=== launching Node A (strict) — pulls + enforces ==="
# node_a writes its clean transcript directly to $SESSION_LOG (survives the
# temp-dir cleanup and any wrapper signal).
SESSION_LOG="$SESSION_LOG" \
  elixir --sname cpa --cookie "$COOKIE" -S mix run --no-start demo/trust_federation/node_a.exs "$DIR_A" "$SHARED" \
  > "$SHARED/a.raw" 2>&1
A_RC=$?
cat "$SESSION_LOG" 2>/dev/null

echo "=== Node B log tail ==="
grep -h "\[B\]" "$SHARED/b.log" || true

exit "$A_RC"

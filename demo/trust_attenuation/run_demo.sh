#!/usr/bin/env bash
# Live capability ATTENUATION demo (CX-tdkq.22, phase 3).
#
# Two real BEAM nodes. Node B (peer) holds the cert chains + one valid
# commit; strict Node A pins only the root anchor and, over the REAL
# import path (catch_up + import_commit → the phase-3 capability gate):
#   - ACCEPTS bob's commit within his root→alice→bob grant (pulled cross-node)
#   - REJECTS a forged-sig cert, an over-broad cert (narrowing violation),
#     a stolen chain (commit-author binding), and an expired cert.
#
# Run from repo root:  bash demo/trust_attenuation/run_demo.sh
# Proves the import/sync seam enforces the chain — NOT a claim about
# cookie-holding cluster members (one trust domain by design).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

COOKIE="attendemo$$"
SHARED="$(mktemp -d /tmp/cp_att_demo.XXXXXX)"
DIR_A="$SHARED/nodeA/.commonplace"
DIR_B="$SHARED/nodeB/.commonplace"
mkdir -p "$DIR_A" "$DIR_B"
SESSION_LOG="${SESSION_LOG:-/tmp/cp_att_session.log}"

echo "=== epmd ==="
epmd -daemon 2>/dev/null || true
sleep 1
pkill -f "sname cpb" 2>/dev/null || true
pkill -f "sname cpa" 2>/dev/null || true
sleep 1

cleanup() {
  pkill -f "sname cpb --cookie $COOKIE" 2>/dev/null || true
  pkill -f "sname cpa --cookie $COOKIE" 2>/dev/null || true
  [ -n "${CP_KEEP_SHARED:-}" ] || rm -rf "$SHARED"
}
trap cleanup EXIT
echo "SHARED=$SHARED"

echo "=== launching Node B (peer) ==="
setsid elixir --sname cpb --cookie "$COOKIE" -S mix run --no-start demo/trust_attenuation/node_b.exs "$DIR_B" "$SHARED" \
  > "$SHARED/b.log" 2>&1 < /dev/null &
disown 2>/dev/null || true

for _ in $(seq 1 240); do
  [ -f "$SHARED/b_ready" ] && break
  sleep 0.5
done
if [ ! -f "$SHARED/b_ready" ]; then
  echo "Node B failed to come up. Log:"; cat "$SHARED/b.log"; exit 1
fi
grep -h "\[B\]" "$SHARED/b.log" || true

echo "=== launching Node A (strict) — pulls + enforces the chain ==="
# node_a self-writes its transcript directly to $SESSION_LOG (a stable
# path that survives the temp-dir cleanup / any wrapper signal).
SESSION_LOG="$SESSION_LOG" \
  elixir --sname cpa --cookie "$COOKIE" -S mix run --no-start demo/trust_attenuation/node_a.exs "$DIR_A" "$SHARED" \
  > "$SHARED/a.raw" 2>&1
A_RC=$?
cat "$SESSION_LOG" 2>/dev/null

echo "=== Node B log tail ==="
grep -h "\[B\]" "$SHARED/b.log" || true
exit "$A_RC"

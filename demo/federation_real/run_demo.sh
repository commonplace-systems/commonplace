#!/usr/bin/env bash
# FEDERATION FOR REAL (move #1, phase D) — two separate-rooted
# workspaces as two plain OS processes. NO shared Erlang cookie, NO
# epmd, NO BEAM distribution: Node B is just an HTTP URL to Node A.
#
#   Node B (agent's home): root registers an agent (creator-signed
#     birth, CX-88mw), delegates it a write-scoped cert (phase 3),
#     the agent authors signed commits; Bandit serves the federation
#     endpoints (CX-orfw).
#   Node A (strict puller): pins ONLY the root pubkey, pulls over
#     plain HTTP (PullClient, CID diff), and its UNCHANGED Gate A
#     decides: in-scope agent commit ACCEPTED (chain verifies to the
#     pinned root), out-of-scope REJECTED, uncertified REJECTED,
#     wrong bearer token 403'd at the door.
#
# This is the claim the trust-arc demos could NOT make (shared-cookie
# BEAM nodes are ONE trust domain by design): genuine cross-trust-
# domain federation with an agent as the principal.
#
# Run from repo root:  bash demo/federation_real/run_demo.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

SHARED="$(mktemp -d /tmp/cp_fed_real.XXXXXX)"
DIR_A="$SHARED/nodeA/.commonplace"
DIR_B="$SHARED/nodeB/.commonplace"
mkdir -p "$DIR_A" "$DIR_B"
SESSION_LOG="${SESSION_LOG:-/tmp/cp_fed_real_session.log}"
PORT=$((43000 + RANDOM % 2000))

cleanup() {
  pkill -f "federation_real/node_b.exs" 2>/dev/null || true
  [ -n "${CP_KEEP_SHARED:-}" ] || rm -rf "$SHARED"
}
trap cleanup EXIT
echo "SHARED=$SHARED  PORT=$PORT"
echo "(note: no epmd, no cookie, no --sname anywhere below)"

echo "=== launching Node B (agent's home + federation HTTP surface) ==="
setsid elixir -S mix run --no-start demo/federation_real/node_b.exs "$DIR_B" "$SHARED" "$PORT" \
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

echo "=== launching Node A (strict puller — separate trust domain) ==="
SESSION_LOG="$SESSION_LOG" \
  elixir -S mix run --no-start demo/federation_real/node_a.exs "$DIR_A" "$SHARED" \
  > "$SHARED/a.raw" 2>&1
A_RC=$?
cat "$SESSION_LOG" 2>/dev/null

echo "=== done (rc=$A_RC) ==="
exit $A_RC

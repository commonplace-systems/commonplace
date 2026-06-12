#!/usr/bin/env bash
# Live proof for move #4 (CX-tdkq.7): :global MoveServer/TickBot retired
# in favor of green tokens.
#
# Reproduces the original incident — a bare extra BEAM node booting
# :commonplace and joining the cluster — and shows: no :global names to
# race, fail-closed idle before attach, green-token moves through the
# BursarClient seam after attach, and TickBot leadership failover
# bounded by the lease TTL when the leader dies.
#
# Run from repo root:  bash demo/bursar_singletons/run_proof.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
exec elixir --sname "bursar_proof_a_$$" -S mix run --no-start demo/bursar_singletons/proof.exs

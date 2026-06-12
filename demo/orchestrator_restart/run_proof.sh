#!/usr/bin/env bash
# Live crash-restart proof for the supervised Orchestrator (CX-tdkq.12).
#
# Boots the REAL :commonplace supervision tree with :orchestrator_on_boot
# in a scratch workspace, declares a managed process, KILLS the
# orchestrator, and asserts: supervisor restart → prior-generation sweep
# → re-reconcile → exactly ONE generation (the old one dead).
#
# Run from repo root:  bash demo/orchestrator_restart/run_proof.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
elixir -S mix run --no-start demo/orchestrator_restart/proof.exs

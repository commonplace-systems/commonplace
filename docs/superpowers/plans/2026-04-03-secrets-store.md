# Secrets Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Safely inject keypairs and secrets into process environments without storing them in CRDT docs or syncing them across nodes.

**Architecture:** Local CubDB at `.commonplace/secrets/`, never synced. CLI commands for CRUD. `$secret:KEY` references in `__processes.json` env maps resolved by orchestrator at spawn time.

**Tech Stack:** CubDB, existing CLI/Orchestrator patterns

**Issue:** CX-zpk

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `apps/commonplace/lib/commonplace/store/secret_store.ex` | Create | CubDB-backed GenServer for secret CRUD |
| `apps/commonplace/lib/commonplace/application.ex` | Modify | Add SecretStore to supervision tree |
| `apps/commonplace/lib/commonplace/process/orchestrator.ex` | Modify | Resolve $secret refs before spawning |
| `apps/commonplace_cli/lib/commonplace/cli/secret.ex` | Create | CLI command: secret set/get/list/delete |
| `apps/commonplace_cli/lib/commonplace/cli.ex` | Modify | Add "secret" to dispatch |
| `test/commonplace/store/secret_store_test.exs` | Create | SecretStore CRUD tests |
| `test/commonplace/process/secret_resolution_test.exs` | Create | Orchestrator env resolution tests |
| `test/commonplace/cli/secret_test.exs` | Create | CLI secret command tests |

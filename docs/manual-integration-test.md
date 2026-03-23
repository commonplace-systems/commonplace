# Manual Integration Test: Bartleby End-to-End

Goal: Get bartleby reliably processing prompts through commonplace — file sync, process management, prompt→output loop all working.

## The Loop

```
 you write prompt ──► disk ──► commonplace import ──► CRDT tree
                                                         │
                                              commonplace serve
                                              (orchestrator manages bartleby)
                                                         │
 you read output  ◄── disk ◄── commonplace export ◄── bartleby writes output
```

The test passes when you can:
1. Write a prompt to `bartleby/prompts.txt`
2. Bartleby picks it up (managed by orchestrator)
3. Bartleby writes to `bartleby/output.txt`
4. Output syncs back through commonplace
5. Repeat reliably

## Stage 1: Workspace Setup

```bash
mkdir -p workspace && cd workspace
commonplace init
```

**Checkpoint:** `.commonplace/root` exists.

## Stage 2: Bartleby File Structure

```bash
mkdir -p bartleby
cp ~/bartleby/system_prompt.txt.default bartleby/system_prompt.txt
cp ~/bartleby/mcp_servers.json.default bartleby/mcp_servers.json
touch bartleby/prompts.txt
touch bartleby/output.txt
```

**Checkpoint:** `ls bartleby/` shows all four files.

## Stage 3: Import Into CRDT

```bash
commonplace import
commonplace ls bartleby
```

**Checkpoint:** `commonplace cat bartleby/prompts.txt` returns empty content (not an error).

## Stage 4: Register Bartleby as Managed Process

```bash
cat > __processes.json << 'EOF'
{
  "bartleby": {
    "command": ["bash", "-c", "cd ~/bartleby && BARTLEBY_WORKING_DIR=$(pwd)/bartleby ./run.sh"],
    "restart": "on-failure"
  }
}
EOF

commonplace import
```

**Checkpoint:** `commonplace cat __processes.json` shows the bartleby entry.

## Stage 5: Start Serving

```bash
commonplace serve
```

**Checkpoint:** `commonplace ps` shows bartleby running.

If bartleby is NOT running:
- Check orchestrator PID: `cat .commonplace/orchestrator.pid`
- Check if process is alive: `kill -0 $(cat .commonplace/orchestrator.pid)`
- Look at bartleby's stderr/stdout for crash info
- Verify the command path resolves correctly

## Stage 6: Send a Prompt

```bash
echo "Hello bartleby, what time is it?" >> bartleby/prompts.txt
commonplace import
```

**Checkpoint:** File change is in the CRDT — `commonplace log bartleby/prompts.txt` shows a new commit.

## Stage 7: Wait for Output

```bash
tail -f bartleby/output.txt
```

**Checkpoint:** Bartleby writes a response.

If no output:
- Is bartleby still running? `commonplace ps`
- Does bartleby see the prompt file? Check `BARTLEBY_WORKING_DIR` resolves
- Is bartleby polling prompts.txt or watching for changes?
- Try `commonplace export` to flush CRDT → disk before bartleby reads

## Stage 8: Verify Round-Trip Through Commonplace

```bash
commonplace import   # pick up bartleby's output
commonplace cat bartleby/output.txt
commonplace log bartleby/output.txt
```

**Checkpoint:** Output is in the CRDT with commit history. This proves the full loop:
prompt on disk → CRDT → orchestrator runs bartleby → output on disk → CRDT.

## Stage 9: Reliability

Run stages 6–8 three more times with different prompts. All three should complete without manual intervention.

**Pass criteria:**
- [ ] Bartleby stays running across all prompts (no crash/restart)
- [ ] Each prompt produces output within a reasonable time
- [ ] Commit history grows correctly (`commonplace log`)
- [ ] No orphan processes after `commonplace serve` is stopped

## Stage 10: Clean Shutdown

```bash
# Stop serving (Ctrl-C or kill orchestrator)
commonplace ps   # should show nothing
ps aux | grep bartleby   # should show nothing
```

**Checkpoint:** No orphan bartleby or commonplace processes remain.

---

## Historical: Rust-Era Results (2025-12-29)

The original test in commonplace-rs used redb + mosquitto + SSE with two sync clients:
- **A → B sync: PASS** — update propagated in 4 seconds
- **B → A sync: FAIL** — sync client never committed after file edit (CP-5p5)

The Elixir rewrite replaces that infrastructure (CubDB, PubSub, LiveView). The sync client bug was Rust-specific.

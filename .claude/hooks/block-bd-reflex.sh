#!/usr/bin/env bash
#
# PreToolUse/Bash hook: block the `bd` reflex in THIS repo only.
#
# WHY (2026-08-08): `bd` is bound to the frozen beads archive. Tickets have
# lived in tix since the 2026-08-05 cutover — tix 854 issues, bd 798 — so
# `bd show <recent-ticket>` returns a confident, well-formed "no issue found"
# for tickets that demonstrably exist. Two agents hit it within an hour; one
# was three lines from reporting six real tickets as fabricated.
#
# ⛔ SCOPE IS THE WHOLE POINT. `~/.local/bin/bd` is GLOBAL — hermes, wimble,
# gastown, turingtest, starloom26, paravel and others are live, legitimate,
# UN-migrated beads users. The claim "bd is frozen as of 2026-08-05" is TRUE
# IN COMMONPLACE AND FALSE IN HERMES. A guard whose premise is repo-local must
# be installed repo-locally, or it becomes a confident wrong answer somewhere
# else — the exact bug we are fixing, inverted and aimed at everyone else.
# Living in .claude/settings.json of this repo is what makes that safe.
#
# ⇒ Therefore: FAIL OPEN. If this cannot tell what it is looking at, it
# ALLOWS. That is the opposite of the store-opener rule (where refusing is
# the feature) and the difference is deliberate: this guards a CLAIM ABOUT
# ONE REPO, so a wrong refusal is worse than a missed catch.

set -uo pipefail

allow() { exit 0; }

INPUT="$(cat)" || allow
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)" || allow
[[ -n "$CMD" ]] || allow

# The deliberate archive read opts out, same escape hatch as bin/bd.
[[ "$CMD" == *"CP_BD_ARCHIVE=1"* ]] && allow

# bin/bd IS the guardrail — it already explains itself. Don't double-block.
[[ "$CMD" =~ (^|[^[:alnum:]_./-])(\./)?bin/bd([[:space:]]|$) ]] && allow

# ⛔ THE CROSS-REPO CARVE-OUT. `cd ~/hermes && bd list` is a LEGITIMATE bd
# call against a live, un-migrated beads store — the frozen-archive claim is
# simply false there. Denying it would ship the "your real tickets don't
# exist" bug to a repo that never had it. Caught by its own test case; the
# obvious pattern denied it.
while read -r target; do
  [[ -z "$target" ]] && continue
  case "$(readlink -f "${target/#\~/$HOME}" 2>/dev/null || echo "$target")" in
    /home/jes/commonplace|/home/jes/commonplace/*) ;;   # still us — keep guarding
    *) allow ;;                                          # left the repo — not our claim
  esac
done < <(printf '%s' "$CMD" | grep -oE '(^|[;&|]|&&)[[:space:]]*cd[[:space:]]+[^;&|]+' | sed -E 's/.*cd[[:space:]]+//; s/[[:space:]]+$//' || true)

# Match `bd` invoked as a COMMAND: at the start, or after a shell separator.
# Deliberately narrow — `bd_show` (the MCP tool), `sbd`, `bdist`, and the
# string "bd" inside a path or a commit message must NOT match.
if [[ "$CMD" =~ (^|[;&|]|&&|\|\||\$\(|^[[:space:]]*)[[:space:]]*bd([[:space:]]+|$) ]]; then
  cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "`bd` is the FROZEN ARCHIVE in this repo (cutover 2026-08-05) and CANNOT SEE any ticket filed since — tix holds 854 issues, bd holds 798. So `bd show CX-xxxx` returns a confident 'no issue found' for tickets that demonstrably exist; a negative from bd is NOT evidence a ticket is missing.\n\nTo check whether a ticket exists:\n  • MCP:  bd_show CX-xxxx  (routes to the tix verbs)\n  • erpc: Commonplace.Bd.Issue.show(root, \"CX-xxxx\", CommitStoreClient) on commonplace_dev@commonplace\n\nWrites are worse: under enforce the bd CLI passes no signing context, the gate refuses the commit, and it prints a minted id for a ticket that was never created (CX-3nf4).\n\nTo read PRE-CUTOVER archive history on purpose, prefix the command with CP_BD_ARCHIVE=1 (or call bin/bd)."
  }
}
JSON
  exit 0
fi

allow

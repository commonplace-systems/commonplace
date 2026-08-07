#!/usr/bin/env bash
# One-file fixture acceptance/red-proof harness. It creates its git fixture
# below the worktree's ignored tmp/ and removes every temporary on exit.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$PROJECT_DIR/.stateproj/fixtures/render-input.jsonl"
CLEAN_EXPORT="$PROJECT_DIR/.stateproj/fixtures/scan-clean.jsonl"
mkdir -p "$PROJECT_DIR/tmp"
TEST_DIR="$(mktemp -d "$PROJECT_DIR/tmp/state-projection.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

make_root() {
  local target="$1"
  mkdir -p "$target"
  printf '%s\n' '# Fixture project' '' '<!-- state-projection:begin -->' 'old pointer' '<!-- state-projection:end -->' '' 'Outside marker sentinel.' >"$target/CLAUDE.md"
}

echo 'RED-PROOF 1A — backdated STATE.md'
make_root "$TEST_DIR/prime"
"$PROJECT_DIR/bin/state-render" --fixture "$FIXTURE" --repo-root "$TEST_DIR/prime" --now 2026-08-07T00:00:00Z >/dev/null
"$PROJECT_DIR/bin/state-prime" --state "$TEST_DIR/prime/STATE.md" --now 2026-08-07T02:00:00Z

echo
echo 'RED-PROOF 1B — deleted STATE.md'
set +e
"$PROJECT_DIR/bin/state-prime" --state "$TEST_DIR/prime/deleted-STATE.md" --now 2026-08-07T02:00:00Z
prime_missing_exit=$?
set -e
echo "exit=$prime_missing_exit"
[ "$prime_missing_exit" -eq 2 ]

echo
echo 'RED-PROOF 1C — fresh STATE.md'
"$PROJECT_DIR/bin/state-prime" --state "$TEST_DIR/prime/STATE.md" --now 2026-08-07T00:30:00Z

echo
echo 'RED-PROOF 2A — planted both-directions discrepancies'
GIT_FIXTURE="$TEST_DIR/git-fixture"
mkdir -p "$GIT_FIXTURE"
git -C "$GIT_FIXTURE" init -q
git -C "$GIT_FIXTURE" config user.email fixture@example.invalid
git -C "$GIT_FIXTURE" config user.name 'State Fixture'
printf '%s\n' fixture >"$GIT_FIXTURE/file.txt"
git -C "$GIT_FIXTURE" add file.txt
GIT_AUTHOR_DATE=2026-08-07T02:30:00Z GIT_COMMITTER_DATE=2026-08-07T02:30:00Z \
  git -C "$GIT_FIXTURE" commit -q -m 'Ship CX-open and CX-shipped' -m 'Close evidence tracked by CX-closed-evidence.'
set +e
"$PROJECT_DIR/bin/tix-truth-scan" \
  --export "$TEST_DIR/prime/.commonplace-state/tix-export.jsonl" \
  --git-repo "$GIT_FIXTURE" \
  --verdict "$TEST_DIR/prime/.commonplace-state/scan-verdict.txt" \
  --now 2026-08-07T03:00:00Z
planted_exit=$?
set -e
echo "exit=$planted_exit"
[ "$planted_exit" -eq 1 ]

echo
echo 'RED-PROOF 2B — clean both-directions fixture'
"$PROJECT_DIR/bin/tix-truth-scan" \
  --export "$CLEAN_EXPORT" \
  --git-repo "$GIT_FIXTURE" \
  --verdict "$TEST_DIR/clean-verdict.txt" \
  --now 2026-08-07T03:00:00Z
echo 'exit=0'

echo
echo 'RED-PROOF 3 — generator idempotency and marker fencing'
make_root "$TEST_DIR/idempotent"
python3 - "$TEST_DIR/idempotent/CLAUDE.md" "$TEST_DIR/outside-before" <<'PYTHON'
import re, sys
body = open(sys.argv[1], encoding="utf-8").read()
open(sys.argv[2], "w", encoding="utf-8").write(re.sub(r"<!-- state-projection:begin -->.*?<!-- state-projection:end -->", "<MARKED>", body, flags=re.S))
PYTHON
"$PROJECT_DIR/bin/state-render" --fixture "$FIXTURE" --repo-root "$TEST_DIR/idempotent" --now 2026-08-07T01:00:00Z >/dev/null
cp "$TEST_DIR/idempotent/STATE.md" "$TEST_DIR/state-first.md"
"$PROJECT_DIR/bin/state-render" --fixture "$FIXTURE" --repo-root "$TEST_DIR/idempotent" --now 2026-08-07T01:15:00Z >/dev/null
python3 - "$TEST_DIR/state-first.md" "$TEST_DIR/idempotent/STATE.md" "$TEST_DIR/idempotent/CLAUDE.md" "$TEST_DIR/outside-before" <<'PYTHON'
import re, sys
first = open(sys.argv[1], encoding="utf-8").read()
second = open(sys.argv[2], encoding="utf-8").read()
normalize = lambda value: re.sub(r"\d{4}-\d\d-\d\dT\d\d:\d\dZ", "<STAMP>", value)
assert normalize(first) == normalize(second), "STATE content drifted beyond woven timestamps"
claude = open(sys.argv[3], encoding="utf-8").read()
outside = re.sub(r"<!-- state-projection:begin -->.*?<!-- state-projection:end -->", "<MARKED>", claude, flags=re.S)
assert outside == open(sys.argv[4], encoding="utf-8").read(), "CLAUDE outside marker changed"
print("PASS: STATE.md byte-identical after timestamp normalization")
print("PASS: CLAUDE.md bytes outside markers untouched")
PYTHON

echo
echo 'RED-PROOF 4 — close without evidence placeholder'
grep -F '`CX-closed-no-evidence`' "$TEST_DIR/idempotent/STATE.md"

echo
echo 'RED-PROOF 5A — widened gap reaches 6h cap and remains fresh'
make_root "$TEST_DIR/clamps"
"$PROJECT_DIR/bin/state-render" --fixture "$FIXTURE" --repo-root "$TEST_DIR/clamps" --now 2026-08-07T00:00:00Z >/dev/null
"$PROJECT_DIR/bin/state-render" --fixture "$FIXTURE" --repo-root "$TEST_DIR/clamps" --now 2026-08-07T03:00:00Z
"$PROJECT_DIR/bin/state-prime" --state "$TEST_DIR/clamps/STATE.md" --now 2026-08-07T03:01:00Z | sed -n '1,4p'

echo
echo 'RED-PROOF 5B — narrow gap stays at 45m floor'
"$PROJECT_DIR/bin/state-render" --fixture "$FIXTURE" --repo-root "$TEST_DIR/clamps" --now 2026-08-07T03:05:00Z

echo
echo 'RED-PROOF 6 — no direct-store shape in delivered scripts'
if rg -n -i 'cubdb|CommitStore\.(start|open)|Store\.open' \
  "$PROJECT_DIR/bin/state-render" "$PROJECT_DIR/bin/tix-truth-scan" "$PROJECT_DIR/bin/state-prime"; then
  echo 'FAIL: forbidden direct-store shape found'
  exit 1
else
  echo 'PASS: 0 matches for CubDB or direct store-open shapes across all three scripts'
fi

echo
echo 'ALL RED-PROOFS PASSED'

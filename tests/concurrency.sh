#!/usr/bin/env bash
set -euo pipefail

# Shared-notebook concurrency test (handoff 06).
#
# Proves the per-loop writer design (handoff 06): two loops on DIFFERENT
# branches pointed at ONE shared notebook each emit under their own
# ralph-<branch> writer, so per-writer JSONL keeps concurrent writes
# contention-free — both entries persist in distinct entries/ralph-*.jsonl
# files and both are returned by a single `lab-notebook sql`, with nothing lost.
#
# This is the "opt-in --notebook shared mode" surface: there is no special
# flag; both runners already accept --notebook <shared-path>, and writer
# disambiguation (LAB_NOTEBOOK_WRITER=ralph-<branch>, set by log_to_notebook)
# does the rest. Here we drive log_to_notebook directly via ralph-lib.sh so the
# test exercises the exact code path the runners use, without needing `claude`.
#
# Mechanics (mirrors tests/setup-sandbox.sh / tests/prompt-diff.sh):
#   - Resolve the repo via BASH_SOURCE, never `which ralph` (the installed
#     ralph may resolve to a different checkout).
#   - Throwaway $TMPDIR workroot, cleaned up on exit. Works in a plain non-git
#     dir (ralph is git-optional; nothing here invokes git).

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v lab-notebook &>/dev/null; then
    echo "SKIP: lab-notebook not on PATH; cannot run concurrency test." >&2
    exit 0
fi

WORKROOT="${TMPDIR:-/tmp}/ralph-concurrency-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$WORKROOT"
cleanup() { cd /; rm -rf "$WORKROOT"; }
trap cleanup EXIT

pass() { echo "  OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# One shared notebook lives under $WORKROOT/shared/.ralph/.lnb. Both loops point
# their NOTEBOOK_DIR at it — this is the --notebook <shared-path> pattern.
SHARED_ROOT="$WORKROOT/shared"
mkdir -p "$SHARED_ROOT/.ralph"
cd "$SHARED_ROOT"
SHARED_DIR="$REPO_DIR/shared"
NOTEBOOK_DIR="$SHARED_ROOT/.ralph/.lnb"

# Initialize the shared notebook once (matches ensure_notebook's init call).
lab-notebook init .ralph --template-path "$SHARED_DIR/coding-dev.yaml" >/dev/null

# Source the shared lib so we exercise the real log_to_notebook code path.
# shellcheck source=/dev/null
source "$SHARED_DIR/ralph-lib.sh"

# emit_as <branch> <message>: emit one entry as the ralph-<branch> writer into
# the shared notebook, exactly as a loop on that branch would.
emit_as() {
    local branch="$1" message="$2"
    local BRANCH="$branch"
    local CONTEXT="$branch"
    log_to_notebook "impl" "$message"
}

###############################################################################
echo "== Two loops on different branches emit into ONE shared notebook =="
###############################################################################
emit_as "ralph/loop-a" "loop A: entry from branch a"
emit_as "ralph/loop-b" "loop B: entry from branch b"

ENTRIES_DIR="$NOTEBOOK_DIR/entries"
[[ -d "$ENTRIES_DIR" ]] || fail "no entries/ dir under shared notebook ($ENTRIES_DIR)"

# Each writer must have its own JSONL — proves disambiguation, no collision.
A_JSONL="$ENTRIES_DIR/ralph-loop-a.jsonl"
B_JSONL="$ENTRIES_DIR/ralph-loop-b.jsonl"
[[ -f "$A_JSONL" ]] || fail "missing per-writer file for loop A: $A_JSONL (have: $(ls "$ENTRIES_DIR"))"
[[ -f "$B_JSONL" ]] || fail "missing per-writer file for loop B: $B_JSONL (have: $(ls "$ENTRIES_DIR"))"
# They must be DISTINCT files (no collapse into one $USER.jsonl).
[[ "$A_JSONL" != "$B_JSONL" ]] || fail "writer files are not distinct"
# No $USER.jsonl should exist — provenance went to the per-branch writers.
USER_JSONL="$ENTRIES_DIR/${USER:-unknown}.jsonl"
[[ ! -f "$USER_JSONL" ]] || fail "entries leaked into a \$USER writer file: $USER_JSONL"
pass "two distinct per-writer files: $(basename "$A_JSONL"), $(basename "$B_JSONL"); no \$USER file"

###############################################################################
echo "== A single lab-notebook sql returns BOTH entries, none lost =="
###############################################################################
# The entries table's writer column is `writer_id`. The sql command may print
# an "Index rebuilt: N entries" banner and a "(N rows)" footer around the data,
# so we match on the substrings we expect rather than parsing exact layout.
ROWS=$(LAB_NOTEBOOK_DIR="$NOTEBOOK_DIR" lab-notebook sql \
    "SELECT writer_id, content FROM entries WHERE content LIKE 'loop %' ORDER BY writer_id" 2>/dev/null || true)

# Total entries across both writers must be exactly 2 (nothing lost/overwritten).
# COUNT(*) is a single value column; isolate the data line (a bare integer) from
# any banner/footer text.
TOTAL=$(LAB_NOTEBOOK_DIR="$NOTEBOOK_DIR" lab-notebook sql \
    "SELECT COUNT(*) FROM entries WHERE content LIKE 'loop %'" 2>/dev/null \
    | grep -Eo '^[0-9]+$' | head -1)
[[ "$TOTAL" == "2" ]] || fail "expected 2 entries across writers, found '$TOTAL'; rows:
$ROWS"

# Both writers must appear in the single query result.
echo "$ROWS" | grep -q "ralph-loop-a" || fail "loop A entry not returned by sql; rows:
$ROWS"
echo "$ROWS" | grep -q "ralph-loop-b" || fail "loop B entry not returned by sql; rows:
$ROWS"
# And the actual message content for each writer survived.
echo "$ROWS" | grep -q "loop A: entry from branch a" || fail "loop A content missing; rows:
$ROWS"
echo "$ROWS" | grep -q "loop B: entry from branch b" || fail "loop B content missing; rows:
$ROWS"
pass "single sql returns both writers' entries (count=2); no lost entries"

echo ""
echo "PASS: shared-notebook per-writer concurrency holds."

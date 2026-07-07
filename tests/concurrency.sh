#!/usr/bin/env bash
set -euo pipefail

# Shared-notebook concurrency test (handoff 06).
#
# Proves the per-loop writer design (handoff 06): two loops on DIFFERENT
# branches pointed at ONE shared notebook each emit under their own
# ralph-<branch> writer, so per-writer JSONL keeps concurrent writes
# contention-free — both entries persist in distinct per-writer ralph-*.jsonl
# files and both are returned by a single `lnb log`, with nothing lost.
#
# To exercise a REAL race (not just sequential disambiguation), the two emits
# run as backgrounded jobs and we `wait` for both: the writers genuinely append
# at the same time. This is deterministically safe precisely because per-writer
# isolation gives each its OWN ralph-<branch>.jsonl — there is no shared
# file for them to clobber, so concurrent appends never collide.
#
# This is the "opt-in --notebook shared mode" surface: there is no special
# flag; both runners already accept --notebook <shared-path>, and writer
# disambiguation (LNB_WRITER=ralph-<branch>, derived by notebook_writer) does
# the rest. Here we derive the writer via notebook_writer (the runners' real
# writer-id code path) and write via `lnb note` directly, so the test exercises
# the per-writer append store without needing `claude`.
#
# Mechanics (mirrors tests/setup-sandbox.sh / tests/prompt-diff.sh):
#   - Resolve the repo via BASH_SOURCE, never `which ralph` (the installed
#     ralph may resolve to a different checkout).
#   - Throwaway $TMPDIR workroot, cleaned up on exit. Works in a plain non-git
#     dir (ralph is git-optional; nothing here invokes git).

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v lnb &>/dev/null; then
    echo "SKIP: lnb not on PATH; cannot run concurrency test." >&2
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

# The min CLI has no init: a notebook dir auto-creates on the first `lnb note`.
# Pre-create the shared notebook dir so its path exists up front.
mkdir -p "$NOTEBOOK_DIR"

# Source the shared lib so we derive the writer via the runners' real
# notebook_writer() (BRANCH -> ralph-<slug>) code path.
# shellcheck source=/dev/null
source "$SHARED_DIR/ralph-lib.sh"

# emit_as <branch> <message>: emit one entry as the ralph-<branch> writer into
# the shared notebook, exactly as a loop on that branch would. The writer id is
# derived by notebook_writer (BRANCH -> ralph-<slug>, the runners' real path)
# and set as LNB_WRITER on the `lnb note` call, so each loop appends to its own
# per-writer JSONL under the shared notebook.
emit_as() {
    local branch="$1" message="$2"
    local BRANCH="$branch"
    local CONTEXT="$branch"
    LNB_DIR="$NOTEBOOK_DIR" LNB_WRITER="$(notebook_writer)" \
        lnb note "$message" --type impl --context "$CONTEXT" \
        branch="$BRANCH" tags=ralph-harness >/dev/null
}

###############################################################################
echo "== Two loops on different branches emit CONCURRENTLY into ONE shared notebook =="
###############################################################################
# Background BOTH emits and wait for the pair, so the two writers append at the
# same time — a genuine race. Each runs in its own subshell, so emit_as's local
# BRANCH/CONTEXT for one loop can't leak into the other. Per-writer isolation
# (distinct .lnb/ralph-<branch>.jsonl) makes this deterministically safe.
emit_as "ralph/loop-a" "loop A: entry from branch a" & pid_a=$!
emit_as "ralph/loop-b" "loop B: entry from branch b" & pid_b=$!
# wait per-pid so a failed background emit fails the test (bare `wait` swallows it).
wait "$pid_a" || fail "concurrent emit for loop-a failed"
wait "$pid_b" || fail "concurrent emit for loop-b failed"

# The min CLI stores one JSONL per writer at the TOP LEVEL of the notebook dir
# (.lnb/<writer>.jsonl) — there is no entries/ subdir.
[[ -d "$NOTEBOOK_DIR" ]] || fail "no shared notebook dir ($NOTEBOOK_DIR)"

# Each writer must have its own JSONL — proves disambiguation, no collision.
A_JSONL="$NOTEBOOK_DIR/ralph-loop-a.jsonl"
B_JSONL="$NOTEBOOK_DIR/ralph-loop-b.jsonl"
[[ -f "$A_JSONL" ]] || fail "missing per-writer file for loop A: $A_JSONL (have: $(ls "$NOTEBOOK_DIR"))"
[[ -f "$B_JSONL" ]] || fail "missing per-writer file for loop B: $B_JSONL (have: $(ls "$NOTEBOOK_DIR"))"
# They must be DISTINCT files (no collapse into one $USER.jsonl).
[[ "$A_JSONL" != "$B_JSONL" ]] || fail "writer files are not distinct"
# No $USER.jsonl should exist — provenance went to the per-branch writers.
USER_JSONL="$NOTEBOOK_DIR/${USER:-unknown}.jsonl"
[[ ! -f "$USER_JSONL" ]] || fail "entries leaked into a \$USER writer file: $USER_JSONL"
pass "two distinct per-writer files: $(basename "$A_JSONL"), $(basename "$B_JSONL"); no \$USER file"

###############################################################################
echo "== A single 'lnb log' returns BOTH entries, none lost =="
###############################################################################
# lnb is the producer; jq is the read path. `lnb log` streams every record from
# every per-writer file as JSONL (one object per line), ascending by ts. We
# slurp the stream with jq and assert over the resulting array.
ROWS=$(LNB_DIR="$NOTEBOOK_DIR" lnb log 2>/dev/null || true)

# Total entries across both writers must be exactly 2 (nothing lost/overwritten).
TOTAL=$(printf '%s\n' "$ROWS" | jq -s '[.[] | select(.content | startswith("loop "))] | length')
[[ "$TOTAL" == "2" ]] || fail "expected 2 entries across writers, found '$TOTAL'; rows:
$ROWS"

# Both writers must appear in the single log stream.
printf '%s\n' "$ROWS" | jq -e -s 'any(.[]; .writer=="ralph-loop-a")' >/dev/null \
    || fail "loop A entry not returned by lnb log; rows:
$ROWS"
printf '%s\n' "$ROWS" | jq -e -s 'any(.[]; .writer=="ralph-loop-b")' >/dev/null \
    || fail "loop B entry not returned by lnb log; rows:
$ROWS"
# And the actual message content for each writer survived.
printf '%s\n' "$ROWS" | jq -e -s 'any(.[]; .content=="loop A: entry from branch a")' >/dev/null \
    || fail "loop A content missing; rows:
$ROWS"
printf '%s\n' "$ROWS" | jq -e -s 'any(.[]; .content=="loop B: entry from branch b")' >/dev/null \
    || fail "loop B content missing; rows:
$ROWS"
pass "single lnb log returns both writers' entries (count=2); no lost entries"

echo ""
echo "PASS: shared-notebook concurrent writes are contention-free (per-writer)."

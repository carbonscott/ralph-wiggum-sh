#!/usr/bin/env bash
set -euo pipefail

# State-cursor + archive + refuse-respin regression test (handoff 05).
#
# Asserts the resolved archive-trigger rule and the G3 refuse-respin guard,
# all driven through cc/ralph-prep.sh (the runnable bookkeeping entry point —
# it triggers archive_previous_run, the refuse-respin guard, and the cursor
# write without needing `claude` to run an agent):
#
#   1. First run (no cursor): records .ralph/state.json, archives NOTHING.
#   2. Same-branch re-run: archives NOTHING (cursor unchanged branch).
#   3. Different-branch run: snapshots ONLY tasks.json into
#      .ralph/archive/<date>-<branch>/ — NO notebook copy.
#   4. An all-green, recorded-complete batch is refused with a clear message;
#      --force overrides it.
#   5. No .ralph-last-branch is ever created (cursor fully migrated).
#
# Mechanics (mirrors tests/prompt-diff.sh / tests/setup-sandbox.sh):
#   - Resolve the repo via BASH_SOURCE, never `which ralph` (the installed
#     ralph may resolve to a different checkout).
#   - Run in a throwaway $TMPDIR sandbox seeded with tests/tasks.json; clean up
#     on exit. Works in a plain non-git dir (ralph is git-optional; nothing
#     here invokes git).

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREP="$REPO_DIR/cc/ralph-prep.sh"

WORKROOT="${TMPDIR:-/tmp}/ralph-archive-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$WORKROOT"
cleanup() { cd /; rm -rf "$WORKROOT"; }
trap cleanup EXIT

SANDBOX="$WORKROOT/sandbox"
mkdir -p "$SANDBOX"
cp "$REPO_DIR/tests/tasks.json" "$SANDBOX/tasks.json"
cd "$SANDBOX"

DATE_STR="$(date +%Y-%m-%d)"
STATE_FILE=".ralph/state.json"

pass() { echo "  OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# Run ralph-prep.sh; diagnostics+status go to $1 (a file), returns its exit
# code (without tripping set -e). Used so we can inspect both exit code and
# message text.
run_prep() {
    local logfile="$1"; shift
    local rc=0
    "$PREP" --task-file tasks.json "$@" >"$logfile" 2>&1 || rc=$?
    return $rc
}

# Guard against a stray .ralph-last-branch anywhere in the sandbox.
assert_no_last_branch() {
    if find "$SANDBOX" -name '.ralph-last-branch' -print -quit | grep -q .; then
        fail "a .ralph-last-branch file was created (cursor not migrated)"
    fi
}

set_branch() {
    local newbranch="$1" tmp
    tmp="$(mktemp "$WORKROOT/tasks.XXXXXX")"
    jq --arg b "$newbranch" '.branch = $b' tasks.json > "$tmp"
    mv "$tmp" tasks.json
}

# tasks.json fixture starts on branch ralph/smoke-test.
BRANCH1="ralph/smoke-test"
BRANCH2="ralph/second-batch"

###############################################################################
echo "== Assertion 1: first run records state.json and archives nothing =="
###############################################################################
LOG="$WORKROOT/log1"
run_prep "$LOG" --iteration 1 || fail "first run exited non-zero: $(cat "$LOG")"

[[ -s "$STATE_FILE" ]] || fail "first run did not create $STATE_FILE"
recorded_branch=$(jq -r '.branch' "$STATE_FILE")
[[ "$recorded_branch" == "$BRANCH1" ]] \
    || fail "state.json branch is '$recorded_branch', expected '$BRANCH1'"
# Schema sanity: last_run present, completed_branch present (null on first run).
[[ "$(jq -r 'has("last_run")' "$STATE_FILE")" == "true" ]] \
    || fail "state.json missing last_run"
[[ "$(jq -r '.completed_branch' "$STATE_FILE")" == "null" ]] \
    || fail "first run should leave completed_branch null"
[[ ! -d ".ralph/archive" ]] || fail "first run created an archive dir: $(ls -R .ralph/archive)"
assert_no_last_branch
pass "state.json recorded (branch=$BRANCH1, completed_branch=null), no archive"

###############################################################################
echo "== Assertion 2: same-branch re-run archives nothing =="
###############################################################################
LOG="$WORKROOT/log2"
run_prep "$LOG" --iteration 2 || fail "same-branch re-run exited non-zero: $(cat "$LOG")"
[[ ! -d ".ralph/archive" ]] || fail "same-branch re-run created an archive dir: $(ls -R .ralph/archive)"
[[ "$(jq -r '.branch' "$STATE_FILE")" == "$BRANCH1" ]] \
    || fail "same-branch re-run changed the recorded branch"
assert_no_last_branch
pass "no archive dir after same-branch re-run"

###############################################################################
echo "== Assertion 3: branch change snapshots ONLY tasks.json, no notebook copy =="
###############################################################################
set_branch "$BRANCH2"
LOG="$WORKROOT/log3"
run_prep "$LOG" --iteration 1 || fail "branch-change run exited non-zero: $(cat "$LOG")"

# Old branch (ralph/smoke-test) folds 'ralph/' off and '/'->'-': "smoke-test".
ARCHIVE_FOLDER=".ralph/archive/$DATE_STR-smoke-test"
[[ -d "$ARCHIVE_FOLDER" ]] || fail "branch change did not create $ARCHIVE_FOLDER (have: $(ls -R .ralph/archive 2>/dev/null))"
[[ -f "$ARCHIVE_FOLDER/tasks.json" ]] || fail "archive folder has no tasks.json snapshot"

# Snapshot must be tasks.json ONLY — no notebook (.lnb) copied in.
extra=$(find "$ARCHIVE_FOLDER" -mindepth 1 ! -name 'tasks.json' -print)
[[ -z "$extra" ]] || fail "archive folder contains more than tasks.json (notebook copied?): $extra"
if find "$ARCHIVE_FOLDER" -name '.lnb' -o -name '*.jsonl' | grep -q .; then
    fail "notebook artifacts found inside the archive folder"
fi
# Cursor now advanced to the new branch.
[[ "$(jq -r '.branch' "$STATE_FILE")" == "$BRANCH2" ]] \
    || fail "cursor did not advance to '$BRANCH2' after transition"
assert_no_last_branch
pass "snapshot is tasks.json only under $ARCHIVE_FOLDER; cursor advanced to $BRANCH2"

###############################################################################
echo "== Assertion 4: all-green recorded-complete batch is refused; --force overrides =="
###############################################################################
# Flip every story to passes:true and record the batch complete.
tmp="$(mktemp "$WORKROOT/tasks.XXXXXX")"
jq '.stories |= map(.passes = true)' tasks.json > "$tmp"; mv "$tmp" tasks.json
run_prep "$WORKROOT/log4-record" --record-complete \
    || fail "--record-complete exited non-zero: $(cat "$WORKROOT/log4-record")"
[[ "$(jq -r '.completed_branch' "$STATE_FILE")" == "$BRANCH2" ]] \
    || fail "--record-complete did not set completed_branch to '$BRANCH2'"

# A plain run must now be refused with exit 3 and a clear message. Clear any
# prompt left by an earlier (non-refused) run so we can prove the refused run
# does not write one.
rm -f ".ralph/prompt.md"
LOG="$WORKROOT/log4-refuse"
rc=0
run_prep "$LOG" --iteration 1 || rc=$?
[[ "$rc" -eq 3 ]] || fail "expected refuse-respin exit 3, got $rc; output: $(cat "$LOG")"
grep -qi "already complete" "$LOG" \
    || fail "refuse-respin message unclear (no 'already complete'): $(cat "$LOG")"
# A refused run must NOT have written a prompt.
[[ ! -f ".ralph/prompt.md" ]] || fail "refused run still wrote .ralph/prompt.md"

# --force overrides the guard: it preps a prompt and exits 0.
LOG="$WORKROOT/log4-force"
run_prep "$LOG" --iteration 1 --force \
    || fail "--force run exited non-zero (guard not bypassed): $(cat "$LOG")"
[[ -f ".ralph/prompt.md" ]] || fail "--force run did not write .ralph/prompt.md"
assert_no_last_branch
pass "batch refused with clear message (exit 3); --force re-spins it (exit 0)"

###############################################################################
echo "== Assertion 5: no .ralph-last-branch anywhere in the sandbox =="
###############################################################################
if find "$SANDBOX" -name '.ralph-last-branch' -print | grep -q .; then
    fail "a .ralph-last-branch file exists in the sandbox"
fi
pass "no .ralph-last-branch created at any point"

echo ""
echo "PASS: state cursor, archive trigger, and refuse-respin guard all hold."
